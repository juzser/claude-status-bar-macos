import Foundation

/// Re-asserts one account's backup Keychain item's ACL so it trusts this
/// app, mirroring `LiveCredentialSelfHeal`'s reasoning for the live item —
/// see its doc comment for the full rationale (`SecAccessCreate` resetting
/// an existing "Always Allow" grant, so this must run at a controlled,
/// bounded cadence rather than on every poll).
///
/// Split from `LiveCredentialSelfHeal` rather than folded into it because
/// the vault is scoped per-account (`AccountCredentialVault.performRead`
/// requires an `accountId`) and never needs to trust `claude`'s own binary
/// path — only this app ever reads or writes the backup vault — so this
/// runs synchronously with no `ClaudeBinaryLocator` lookup.
///
/// Exists to close Finding #2: `AccountCredentialVault.defaultReader` used
/// to have no `kSecUseAuthenticationUI` flag at all, so it was free to
/// prompt on every poll cycle for every inactive account and during every
/// switch. Now that `defaultReader` is non-interactive
/// (`AccountCredentialVault.performRead`'s default), an account whose vault
/// item isn't yet trusted would otherwise just silently fail every read
/// until this repairs it once, interactively, on a controlled cadence.
public enum AccountVaultSelfHeal {
    public static func run(
        accountId: String,
        diagnosticLog: URL? = nil,
        isTrusted: (String) -> Bool = { AccountCredentialVault.isAlreadyTrusted(accountId: $0) },
        read: (String) -> (data: Data?, status: KeychainStatus) = { AccountCredentialVault.repairReadWithStatus(accountId: $0) },
        write: (Data, String, [String]) -> Bool = { data, accountId, trustedPaths in
            AccountCredentialVault.repairWrite(accountId: accountId, data, trustedPaths: trustedPaths)
        },
        trustedPaths: () -> [String] = { [Bundle.main.bundlePath] }
    ) -> Bool {
        if isTrusted(accountId) {
            writeDiagnostic("vault self-heal skipped for \(accountId): already trusted", to: diagnosticLog)
            return true
        }
        let (data, status) = read(accountId)
        guard let data else {
            writeDiagnostic("vault self-heal skipped for \(accountId): no backup found (status: \(status.description))",
                            to: diagnosticLog)
            return false
        }
        let succeeded = write(data, accountId, trustedPaths())
        writeDiagnostic(succeeded ? "vault self-heal succeeded for \(accountId)"
                                  : "vault self-heal failed for \(accountId): write rejected",
                        to: diagnosticLog)
        return succeeded
    }

    /// Filters `accounts` down to the ones `usageInputs(_:)` should call
    /// `run(accountId:)` for this cycle: inactive accounts (the only ones
    /// `TokenResolution.resolve` ever reads the vault for — active accounts
    /// come from the shared live Keychain item instead) not already
    /// attempted this launch. Extracted as a pure function so `AppState`'s
    /// per-launch gating (Finding #2's proactive half) is testable without a
    /// live Keychain: mirrors `LiveCredentialSelfHeal`'s "once per launch,
    /// not on a timer" reasoning, but scoped per-account rather than global
    /// since a new account can be added mid-session and would otherwise
    /// never get its first (and possibly only necessary) repair.
    public static func accountsNeedingSelfHeal(
        _ accounts: [Account],
        alreadyAttempted: Set<String>
    ) -> [Account] {
        accounts.filter { !$0.isActive && !alreadyAttempted.contains($0.id) }
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
