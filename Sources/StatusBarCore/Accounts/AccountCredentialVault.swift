import Foundation
import Security

/// One account's backed-up live state: the credential blob normally stored
/// under the `"Claude Code-credentials"` Keychain service, plus the
/// `"oauthAccount"` JSON block normally stored in `~/.claude.json`. Bundled
/// into one vault entry so a switch only ever backs up/restores one thing
/// per account, not two independently-failable things.
public struct CredentialBackup: Codable, Sendable, Equatable {
    public let liveCredentials: Data
    public let oauthAccountBlock: Data?

    public init(liveCredentials: Data, oauthAccountBlock: Data?) {
        self.liveCredentials = liveCredentials
        self.oauthAccountBlock = oauthAccountBlock
    }
}

/// Stores per-account `CredentialBackup`s in the macOS Keychain under a
/// service distinct from the live credential item, so backups get their own
/// (tighter, app-only) ACL rather than sharing the live item's trust list.
public enum AccountCredentialVault {
    public static let service = "ClaudeStatusBar-backup"

    public static func read(
        accountId: String,
        reader: (String, String) -> Data? = defaultReader
    ) -> CredentialBackup? {
        guard let data = reader(service, accountId) else { return nil }
        return try? JSONDecoder().decode(CredentialBackup.self, from: data)
    }

    public static func write(
        accountId: String,
        _ backup: CredentialBackup,
        writer: (Data, String, String) -> Bool = defaultWriter
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(backup) else { return false }
        return writer(data, service, accountId)
    }

    /// Finding #2: this used to be the only Sec* call site anywhere in the
    /// app with no `kSecUseAuthenticationUI` flag at all — meaning macOS's
    /// implicit default (Allow) applied, so this read was free to prompt.
    /// It's called every poll cycle for every inactive account and during
    /// every switch (`NativeAccountSwitcher.switchTo`'s `readVaultBackup`),
    /// making it the most likely source of the reported "sometimes on
    /// reopening a session" prompts. `allowInteractive` defaults to false
    /// here for exactly that reason; `AccountVaultSelfHeal` is the one place
    /// that opts in, on a controlled, logged, once-per-launch cadence — the
    /// same split `AccountDiscovery.performKeychainRead`/
    /// `defaultInteractiveKeychainReader` already established for the live
    /// item's reads.
    public static func defaultReader(service: String, accountId: String) -> Data? {
        performRead(service: service, accountId: accountId)
    }

    public static func defaultInteractiveReader(service: String, accountId: String) -> Data? {
        performRead(service: service, accountId: accountId, allowInteractive: true)
    }

    static func performRead(
        service: String,
        accountId: String,
        allowInteractive: Bool = false,
        onStatus: (KeychainStatus) -> Void = { _ in },
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    ) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowInteractive {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = copyMatching(query as CFDictionary, &item)
        onStatus(KeychainStatus(status))
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

    /// Non-interactive probe mirroring `LiveCredentialWriter.isAlreadyTrusted`
    /// — lets `AccountVaultSelfHeal` skip `repairWrite` (and the ACL reset it
    /// implies) when this account's vault item is already trusted.
    public static func isAlreadyTrusted(
        accountId: String,
        prober: (String, String) -> Bool = defaultTrustProbe
    ) -> Bool {
        prober(service, accountId)
    }

    public static func defaultTrustProbe(service: String, accountId: String) -> Bool {
        performRead(service: service, accountId: accountId) != nil
    }

    /// Interactive repair read — used only from `AccountVaultSelfHeal`'s
    /// repair branch, never from a routine/poll path. Same reasoning as
    /// `LiveCredentialWriter.repairRead`.
    public static func repairRead(
        accountId: String,
        reader: (String, String) -> Data? = defaultInteractiveReader
    ) -> Data? {
        reader(service, accountId)
    }

    public static func repairReadWithStatus(
        accountId: String,
        reader: (String, String) -> (data: Data?, status: KeychainStatus) = defaultInteractiveReaderWithStatus
    ) -> (data: Data?, status: KeychainStatus) {
        reader(service, accountId)
    }

    public static func defaultInteractiveReaderWithStatus(service: String, accountId: String) -> (data: Data?, status: KeychainStatus) {
        var capturedStatus = KeychainStatus.itemNotFound
        let data = performRead(service: service, accountId: accountId, allowInteractive: true, onStatus: { capturedStatus = $0 })
        return (data, capturedStatus)
    }

    /// Lets `NativeAccountSwitcher.switchTo`'s backup-read-miss diagnostic
    /// distinguish *why* the read missed — genuinely absent vs. blocked
    /// because the process isn't trusted yet. Mirrors
    /// `repairReadWithStatus`'s tuple-return convention.
    public static func readStatus(
        accountId: String,
        reader: (String, String) -> (data: Data?, status: KeychainStatus) = defaultReaderWithStatus
    ) -> KeychainStatus {
        reader(service, accountId).status
    }

    public static func defaultReaderWithStatus(service: String, accountId: String) -> (data: Data?, status: KeychainStatus) {
        var capturedStatus = KeychainStatus.itemNotFound
        let data = performRead(service: service, accountId: accountId, onStatus: { capturedStatus = $0 })
        return (data, capturedStatus)
    }

    public static func defaultWriter(data: Data, service: String, accountId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
            kSecAttrAccount as String: accountId,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        // ThisDeviceOnly: unlike the live credential item (which `claude`
        // also reads), this backup vault is app-private and never needs to
        // migrate via an iCloud Keychain / device-to-device restore.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Repair write for a vault item's ACL, mirroring
    /// `LiveCredentialWriter.performWrite`: unlike `defaultWriter` (which
    /// leaves whatever implicit ACL `SecItemAdd` assigns), this builds an
    /// explicit `SecAccess` naming `trustedPaths` — this app's own bundle
    /// path, since `claude` never reads the backup vault directly — so a
    /// later `performRead` (non-interactive) can succeed without a prompt.
    public static func repairWrite(
        accountId: String,
        _ data: Data,
        trustedPaths: [String],
        writer: (Data, String, String, [String]) -> Bool = defaultRepairWriter
    ) -> Bool {
        writer(data, service, accountId, trustedPaths)
    }

    public static func defaultRepairWriter(data: Data, service: String, accountId: String, trustedPaths: [String]) -> Bool {
        performRepairWrite(data: data, service: service, accountId: accountId, trustedPaths: trustedPaths)
    }

    /// Update-then-add, never delete-then-add: a failed `add` after a
    /// successful `delete` would destroy the vault backup with no rollback,
    /// which is worse than leaving a stale item in place. Mirrors
    /// `LiveCredentialWriter.performWrite`'s contract — try `update` first;
    /// fall back to `add` only when `update` reports the item doesn't exist
    /// yet; any other update failure returns false without ever calling
    /// `add` or touching the existing item.
    static func performRepairWrite(
        data: Data,
        service: String,
        accountId: String,
        trustedPaths: [String],
        add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd,
        update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
    ) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
            kSecAttrAccount as String: accountId,
        ]

        let trustedApps: [SecTrustedApplication] = trustedPaths.compactMap { path in
            var app: SecTrustedApplication?
            SecTrustedApplicationCreateFromPath(path, &app)
            return app
        }
        var access: SecAccess?
        SecAccessCreate(service as CFString, trustedApps as CFArray, &access)

        var newAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow,
        ]
        if let access {
            newAttributes[kSecAttrAccess as String] = access
        }

        let updateStatus = update(query as CFDictionary, newAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addAttributes = query
        for (key, value) in newAttributes {
            addAttributes[key] = value
        }
        return add(addAttributes as CFDictionary, nil) == errSecSuccess
    }
}
