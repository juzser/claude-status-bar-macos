import Foundation
import Security

/// Reads and writes the live `"Claude Code-credentials"` Keychain item —
/// the same item `claude` itself reads. Writing sets an explicit
/// `SecAccess`/`SecTrustedApplication` ACL naming both `claude` and this app,
/// rather than the default single-writer ACL `security add-generic-password
/// -U` leaves behind (that reset is the root cause of the intermittent
/// Keychain re-prompt this app's self-heal and account-switching paths
/// exist to fix).
public enum LiveCredentialWriter {
    public static let service = "Claude Code-credentials"

    public static func read(reader: (String) -> Data? = AccountDiscovery.defaultKeychainReader) -> Data? {
        reader(service)
    }

    /// Non-interactive probe: can the current process already read the live
    /// item without macOS needing to show a Keychain prompt? Uses
    /// `kSecUseAuthenticationUIFail` so an untrusted caller gets
    /// `errSecInteractionNotAllowed` back instead of a dialog.
    ///
    /// `LiveCredentialSelfHeal` calls this before touching the ACL: skipping
    /// the rewrite when the app is already trusted avoids resetting an
    /// "Always Allow" grant that's already in place (see
    /// `LiveCredentialSelfHeal`'s doc comment on why `SecAccessCreate` makes
    /// that rewrite itself destructive).
    public static func isAlreadyTrusted(prober: (String) -> Bool = defaultTrustProbe) -> Bool {
        prober(service)
    }

    public static func defaultTrustProbe(service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
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
    /// matches what `claude` itself keys on when looking it up.
    /// `account` defaults to the current macOS username via `defaultWrite`:
    /// forensic inspection of a real `claude`-written item (a single
    /// narrowly-scoped `security find-generic-password -s "Claude
    /// Code-credentials"` lookup) showed `acct` set to the OS username, not a
    /// fixed literal such as `"claude"`.
    ///
    /// Uses `SecItemUpdate`-or-add rather than delete-then-add: a delete
    /// followed by a failed add would leave the live item entirely missing,
    /// which is worse than simply leaving the existing item untouched on
    /// failure. Falls back to `add` only when `update` reports the item
    /// doesn't exist yet; any other update failure is reported as failure
    /// without touching the existing item.
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

    public static func writeValue(
        _ data: Data,
        writer: (Data, String) -> Bool = defaultWriteValue
    ) -> Bool {
        writer(data, service)
    }

    public static func defaultWriteValue(data: Data, service: String) -> Bool {
        performWriteValue(data: data, service: service, account: NSUserName())
    }

    /// Value-only update — never touches `kSecAttrAccess`, unlike
    /// `performWrite`. Account switching only needs to change the
    /// credential bytes; rewriting the ACL on every switch is what resets
    /// an existing "Always Allow" grant (see `performWrite`'s doc comment).
    /// `LiveCredentialSelfHeal` owns re-asserting the ACL, gated behind its
    /// own non-interactive trust probe on a deliberately bounded cadence —
    /// this path stays out of that business entirely.
    static func performWriteValue(
        data: Data,
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

        let newAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

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

    /// Result of running a fixed-path system binary via `defaultRun`.
    public struct ShellResult {
        public let stdout: String
        public let stderr: String
        public let exitCode: Int32
    }

    /// Runs `binary arguments` directly (no shell) and captures both stdout
    /// and stderr. Modeled on `InteractiveShellRunner.captureOutput`'s
    /// `Process`/`Pipe`/`withCheckedContinuation` idiom, but simplified for
    /// fixed system paths (`/usr/bin/codesign`, `/usr/bin/security`) that
    /// need no interactive-shell PATH resolution, and with no timeout: `security
    /// set-generic-password-partition-list` may need to block on a genuine
    /// SecurityAgent prompt, so it must not be artificially killed.
    public static func defaultRun(binary: String, arguments: [String]) async -> ShellResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.terminationHandler = { finished in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
                continuation.resume(returning: ShellResult(stdout: stdout, stderr: stderr,
                                                            exitCode: finished.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: ShellResult(stdout: "", stderr: "process.run() failed: \(error)",
                                                            exitCode: -1))
                return
            }
        }
    }

    /// `partition_id` (the `teamid:` ACL entries `set-generic-password-partition-list`
    /// grants) is a separate authorization gate from the `SecAccess`/
    /// `SecTrustedApplication` `applications` list `performWrite` already
    /// sets — command-line-invoked `claude` needs this one too. Looked up
    /// dynamically via `codesign` rather than hardcoded so a future
    /// re-signed `claude` binary under a different team doesn't silently
    /// break this.
    public static func teamIdentifier(
        forExecutableAt path: String,
        run: (String, [String]) async -> ShellResult = defaultRun
    ) async -> String? {
        let result = await run("/usr/bin/codesign", ["-dv", "--verbose=4", path])
        for line in result.stderr.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = line.dropFirst("TeamIdentifier=".count).trimmingCharacters(in: .whitespaces)
            return value == "not set" ? nil : value
        }
        return nil
    }

    /// Grants `teamID` (plus the `apple-tool:`/`apple:` markers `claude`'s
    /// own writes use) onto the live item's `partition_id` list — the ACL
    /// gate `SecAccessCreate` doesn't touch, see `teamIdentifier`'s doc
    /// comment.
    public static func setPartitionList(
        teamID: String,
        account: String,
        service: String = service,
        run: (String, [String]) async -> ShellResult = defaultRun
    ) async -> Bool {
        let result = await run("/usr/bin/security", [
            "set-generic-password-partition-list",
            "-S", "apple-tool:,apple:,teamid:\(teamID)",
            "-s", service,
            "-a", account,
        ])
        return result.exitCode == 0
    }
}
