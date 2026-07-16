import Foundation
import Security

/// Reads and writes the live `"Claude Code-credentials"` Keychain item —
/// the same item `claude` itself reads. Writing sets an explicit
/// `SecAccess`/`SecTrustedApplication` ACL naming both `claude` and this app,
/// rather than the default single-writer ACL `security add-generic-password
/// -U` leaves behind (that reset is the root cause of the intermittent
/// Keychain re-prompt cux used to cause).
public enum LiveCredentialWriter {
    public static let service = "Claude Code-credentials"

    public static func read(reader: (String) -> Data? = AccountDiscovery.defaultKeychainReader) -> Data? {
        reader(service)
    }

    public static func write(
        _ data: Data,
        trustedPaths: [String],
        writer: (Data, [String], String) -> Bool = defaultWrite
    ) -> Bool {
        writer(data, trustedPaths, service)
    }

    public static func defaultWrite(data: Data, trustedPaths: [String], service: String) -> Bool {
        performWrite(data: data, trustedPaths: trustedPaths, service: service, account: NSUserName())
    }

    /// Queries on `kSecAttrService`+`kSecAttrAccount` (not just
    /// `kSecAttrLabel`, as the previous implementation did) so the item
    /// matches what `claude`/`cux` themselves key on when looking it up.
    /// `account` defaults to the current macOS username via `defaultWrite`:
    /// forensic inspection of a real `claude`-written item (a single
    /// narrowly-scoped `security find-generic-password -s "Claude
    /// Code-credentials"` lookup) showed `acct` set to the OS username, not a
    /// fixed literal such as `"claude"`.
    ///
    /// Uses `SecItemUpdate`-or-add rather than delete-then-add: a delete
    /// followed by a failed add would leave the live item entirely missing,
    /// which is worse than anything the old `cux switch` path could do since
    /// it never touched this item directly. Falls back to `add` only when
    /// `update` reports the item doesn't exist yet; any other update failure
    /// is reported as failure without touching the existing item.
    static func performWrite(
        data: Data,
        trustedPaths: [String],
        service: String,
        account: String,
        update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate,
        add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
    ) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
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

    /// Non-nil entries only — `claudePath` is nil when `claude`'s binary
    /// can't be resolved (see `resolvedClaudePath`), in which case the live
    /// item's ACL falls back to app-only trust.
    public static func trustedPaths(thisAppPath: String, claudePath: String?) -> [String] {
        [thisAppPath, claudePath].compactMap { $0 }
    }

    public static let claudeBinaryCandidates: [String] = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/local/claude").path,
    ]

    public static func resolvedClaudePath(
        candidates: [String] = claudeBinaryCandidates,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        candidates.first(where: isExecutable)
    }
}
