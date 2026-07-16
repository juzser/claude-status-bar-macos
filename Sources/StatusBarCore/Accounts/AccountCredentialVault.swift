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

    public static func defaultReader(service: String, accountId: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
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
        // ThisDeviceOnly: unlike the live credential item (which claude/cux
        // also read), this backup vault is app-private and never needs to
        // migrate via an iCloud Keychain / device-to-device restore.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
