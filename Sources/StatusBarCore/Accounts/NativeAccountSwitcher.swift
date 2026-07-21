import Foundation

/// Switches the active Claude account by writing directly to the
/// `"Claude Code-credentials"` Keychain item and `~/.claude.json`'s
/// `"oauthAccount"` block, in a staging order chosen so a failure partway
/// through can never leave the two out of sync with each other: read target
/// backup -> back up outgoing live state -> write target live credentials
/// -> write target live oauthAccount block (rolling back the credentials
/// write if this fails) -> persist the new active id.
public actor NativeAccountSwitcher {
    private let stateFile: URL
    private let diagnosticLog: URL?
    private let readVaultBackup: (String) -> CredentialBackup?
    private let readVaultBackupStatus: (String) -> KeychainStatus
    private let writeVaultBackup: (String, CredentialBackup) -> Bool
    private let vaultSelfHeal: (String) -> Bool
    private let readLiveCredentials: () -> Data?
    private let writeLiveCredentials: (Data) async -> Bool
    private let readLiveOauthBlock: () -> Data?
    private let writeLiveOauthBlock: (Data?) -> Bool
    private let loadState: (URL) -> NativeAccountState
    private let saveState: (NativeAccountState, URL) -> Bool

    public init(
        stateFile: URL = AppPaths().root.appendingPathComponent("native-accounts.json"),
        diagnosticLog: URL? = AppPaths().root.appendingPathComponent("native-switch.log"),
        readVaultBackup: @escaping (String) -> CredentialBackup? = { AccountCredentialVault.read(accountId: $0) },
        // Lets switchTo's backup-read-miss diagnostic say *why* it missed
        // (genuinely absent vs. blocked because the process isn't trusted
        // yet). Queried only on that miss path, never on the happy path, so
        // it costs nothing when the backup read succeeds.
        readVaultBackupStatus: @escaping (String) -> KeychainStatus = { AccountCredentialVault.readStatus(accountId: $0) },
        writeVaultBackup: @escaping (String, CredentialBackup) -> Bool = { AccountCredentialVault.write(accountId: $0, $1) },
        // Deliberately the interactive repair read (mirrors
        // LiveCredentialSelfHeal's `read`): switchTo is always
        // user-initiated, never a background poll, so a prompt here — to
        // read the *current* live credentials before backing them up — is
        // expected rather than a bug.
        readLiveCredentials: @escaping () -> Data? = { LiveCredentialWriter.repairRead() },
        writeLiveCredentials: @escaping (Data) async -> Bool = { data in
            LiveCredentialWriter.writeValue(data)
        },
        readLiveOauthBlock: @escaping () -> Data? = { NativeAccountSwitcher.defaultReadLiveOauthBlock() },
        writeLiveOauthBlock: @escaping (Data?) -> Bool = { blockData in
            guard let blockData else { return true }
            return NativeAccountSwitcher.defaultWriteLiveOauthBlock(blockData)
        },
        loadState: @escaping (URL) -> NativeAccountState = NativeAccountStore.load,
        saveState: @escaping (NativeAccountState, URL) -> Bool = { state, file in
            (try? NativeAccountStore.save(state, to: file)) != nil
        },
        // `nil` rather than a closure default: the real default has to close
        // over this initializer's own `diagnosticLog` parameter (otherwise
        // switch-path vault self-heal writes nothing to `native-switch.log`),
        // and `self` isn't available this early, so it is built below.
        vaultSelfHeal: ((String) -> Bool)? = nil
    ) {
        self.stateFile = stateFile
        self.diagnosticLog = diagnosticLog
        self.readVaultBackup = readVaultBackup
        self.readVaultBackupStatus = readVaultBackupStatus
        self.writeVaultBackup = writeVaultBackup
        self.vaultSelfHeal = vaultSelfHeal ?? { accountId in
            AccountVaultSelfHeal.run(accountId: accountId, diagnosticLog: diagnosticLog)
        }
        self.readLiveCredentials = readLiveCredentials
        self.writeLiveCredentials = writeLiveCredentials
        self.readLiveOauthBlock = readLiveOauthBlock
        self.writeLiveOauthBlock = writeLiveOauthBlock
        self.loadState = loadState
        self.saveState = saveState
    }

    public func switchTo(account: Account) async -> Bool {
        let state = loadState(stateFile)
        guard state.activeId != account.id else { return true }

        // Re-establish trust for the target account's vault item before
        // reading it: readVaultBackup is now non-interactive (Finding #2),
        // so without this an account whose backup isn't yet trusted would
        // just fail here on every switch attempt.
        //
        // This repair read and the one below for the *outgoing* account's
        // live credentials (`readLiveCredentials`, via
        // `LiveCredentialWriter.repairRead`) are both interactive-capable, so
        // a switch that hits distrust on both sides can surface two prompts
        // back to back. Accepted: switchTo only ever runs from a
        // user-initiated action, never a background poll, so both prompts
        // land inside one bounded, expected user action.
        _ = vaultSelfHeal(account.id)

        guard let backup = readVaultBackup(account.id) else {
            let status = readVaultBackupStatus(account.id)
            writeDiagnostic("switch to \(account.id) failed: no backup credentials found (status: \(status.description))")
            return false
        }

        guard let currentLiveCredentials = readLiveCredentials() else {
            writeDiagnostic("switch to \(account.id) failed: could not read current live credentials")
            return false
        }
        let currentLiveOauthBlock = readLiveOauthBlock()

        if let outgoingId = state.activeId {
            let outgoingBackup = CredentialBackup(liveCredentials: currentLiveCredentials,
                                                  oauthAccountBlock: currentLiveOauthBlock)
            guard writeVaultBackup(outgoingId, outgoingBackup) else {
                writeDiagnostic("switch to \(account.id) failed: could not back up outgoing account \(outgoingId)")
                return false
            }
        }

        guard await writeLiveCredentials(backup.liveCredentials) else {
            writeDiagnostic("switch to \(account.id) failed: could not write live credentials")
            return false
        }

        guard writeLiveOauthBlock(backup.oauthAccountBlock) else {
            _ = await writeLiveCredentials(currentLiveCredentials)
            _ = writeLiveOauthBlock(currentLiveOauthBlock)
            writeDiagnostic("switch to \(account.id) failed: could not write oauthAccount block, rolled back")
            return false
        }

        var newState = state
        newState.activeId = account.id
        guard saveState(newState, stateFile) else {
            writeDiagnostic("switch to \(account.id): live swap succeeded but state save failed")
            return false
        }

        writeDiagnostic("switch to \(account.id) succeeded")
        return true
    }

    private func writeDiagnostic(_ message: String) {
        guard let diagnosticLog else { return }
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: diagnosticLog) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: diagnosticLog)
        }
    }

    /// `~/.claude.json`'s top-level `"oauthAccount"` key, treated as an
    /// opaque JSON sub-object — this app never interprets its fields except
    /// via `AccountDiscovery.emailAddress(from:)` /
    /// `.organizationUuid(from:)` when capturing a brand-new login.
    public static func defaultReadLiveOauthBlock(
        configFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    ) -> Data? {
        guard let data = try? Data(contentsOf: configFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = obj["oauthAccount"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: block)
    }

    public static func defaultWriteLiveOauthBlock(
        _ blockData: Data,
        configFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    ) -> Bool {
        guard let blockObj = try? JSONSerialization.jsonObject(with: blockData) else { return false }
        var config: [String: Any] = [:]
        if let existing = try? Data(contentsOf: configFile),
           let existingObj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            config = existingObj
        }
        config["oauthAccount"] = blockObj
        guard let newData = try? JSONSerialization.data(withJSONObject: config) else { return false }
        return (try? AtomicFile.write(newData, to: configFile)) != nil
    }
}
