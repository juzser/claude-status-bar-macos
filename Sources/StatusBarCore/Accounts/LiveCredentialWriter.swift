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
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let trustedApps: [SecTrustedApplication] = trustedPaths.compactMap { path in
            var app: SecTrustedApplication?
            SecTrustedApplicationCreateFromPath(path, &app)
            return app
        }
        var access: SecAccess?
        SecAccessCreate(service as CFString, trustedApps as CFArray, &access)

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if let access {
            attributes[kSecAttrAccess as String] = access
        }
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
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
