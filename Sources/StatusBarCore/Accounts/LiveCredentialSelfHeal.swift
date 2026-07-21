import Foundation

/// Re-asserts the live `"Claude Code-credentials"` Keychain item's ACL so it
/// trusts this app, independent of `NativeAccountSwitcher.switchTo()` ever
/// succeeding. `LiveCredentialWriter.write`'s ACL fix (see its doc comment)
/// used to only run as a side effect of a successful switch — an account
/// whose only switch attempt fails (e.g. a migrated native account with no
/// vault backup) never benefited from it, and kept hitting macOS's Keychain
/// prompt on every `TokenResolution` `keychainFallback` read instead.
///
/// Meant to run once per app launch, not on a timer: `SecAccessCreate`
/// builds a fresh access object on every call, and re-applying an ACL resets
/// any "Always Allow" grant already given for it — calling this every poll
/// cycle would trade one re-prompt problem for a smaller but still
/// recurring one.
///
/// Running once per launch still resets that grant once per launch, so
/// frequent relaunches reproduce the same re-prompt at a lower frequency.
/// `isTrusted` probes (non-interactively, via
/// `LiveCredentialWriter.isAlreadyTrusted`) whether the ACL already covers
/// this app before rewriting it — when it does, `read`/`write` are skipped
/// entirely and the existing "Always Allow" grant survives untouched.
public enum LiveCredentialSelfHeal {
    public static func run(
        diagnosticLog: URL? = nil,
        isTrusted: () -> Bool = { LiveCredentialWriter.isAlreadyTrusted() },
        // Deliberately the *interactive* repair read (Finding #1): this
        // branch only runs after the non-interactive `isTrusted` probe above
        // has already failed, so a prompt firing here — to (re-)establish
        // trust — is expected. The previous default routed through the same
        // non-interactive read the probe uses, which meant it always failed
        // identically right after the probe did, and this write/ACL-repair
        // step could never run.
        read: () -> (data: Data?, status: KeychainStatus) = { LiveCredentialWriter.repairReadWithStatus() },
        write: (Data, [String]) -> Bool = { data, paths in LiveCredentialWriter.write(data, trustedPaths: paths) },
        trustedPaths: () async -> [String] = {
            let claudePath = await ClaudeBinaryLocator.shared.resolve()
            return LiveCredentialWriter.trustedPaths(thisAppPath: Bundle.main.bundlePath, claudePath: claudePath)
        }
    ) async -> Bool {
        if isTrusted() {
            writeDiagnostic("self-heal ACL skipped: already trusted", to: diagnosticLog)
            return true
        }
        let (data, status) = read()
        guard let data else {
            writeDiagnostic("self-heal ACL skipped: no live credentials found (status: \(status.description))",
                            to: diagnosticLog)
            return false
        }
        let succeeded = write(data, await trustedPaths())
        writeDiagnostic(succeeded ? "self-heal ACL succeeded" : "self-heal ACL failed: write rejected",
                        to: diagnosticLog)
        return succeeded
    }

    private static func writeDiagnostic(_ message: String, to log: URL?) {
        guard let log else { return }
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: log)
        }
    }
}
