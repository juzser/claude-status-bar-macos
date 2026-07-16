import Foundation

/// Switches the active Claude account by writing directly to the
/// `"Claude Code-credentials"` Keychain item and `~/.claude.json`'s
/// `"oauthAccount"` block, mirroring cux's `SwitchTo` staging order:
/// read target backup -> back up outgoing live state -> write target live
/// credentials -> write target live oauthAccount block (rolling back the
/// credentials write if this fails) -> persist the new active id.
public actor NativeAccountSwitcher {
    private let stateFile: URL
    private let diagnosticLog: URL?
    private let readVaultBackup: (String) -> CredentialBackup?
    private let writeVaultBackup: (String, CredentialBackup) -> Bool
    private let readLiveCredentials: () -> Data?
    private let writeLiveCredentials: (Data) -> Bool
    private let readLiveOauthBlock: () -> Data?
    private let writeLiveOauthBlock: (Data?) -> Bool
    private let loadState: (URL) -> NativeAccountState
    private let saveState: (NativeAccountState, URL) -> Bool

    public init(
        stateFile: URL = AppPaths().root.appendingPathComponent("native-accounts.json"),
        diagnosticLog: URL? = AppPaths().root.appendingPathComponent("native-switch.log"),
        readVaultBackup: @escaping (String) -> CredentialBackup? = { AccountCredentialVault.read(accountId: $0) },
        writeVaultBackup: @escaping (String, CredentialBackup) -> Bool = { AccountCredentialVault.write(accountId: $0, $1) },
        readLiveCredentials: @escaping () -> Data? = { LiveCredentialWriter.read() },
        writeLiveCredentials: @escaping (Data) -> Bool = { data in
            LiveCredentialWriter.write(data, trustedPaths: LiveCredentialWriter.trustedPaths(
                thisAppPath: Bundle.main.bundlePath,
                claudePath: LiveCredentialWriter.resolvedClaudePath()))
        },
        readLiveOauthBlock: @escaping () -> Data? = { NativeAccountSwitcher.defaultReadLiveOauthBlock() },
        writeLiveOauthBlock: @escaping (Data?) -> Bool = { blockData in
            guard let blockData else { return true }
            return NativeAccountSwitcher.defaultWriteLiveOauthBlock(blockData)
        },
        loadState: @escaping (URL) -> NativeAccountState = NativeAccountStore.load,
        saveState: @escaping (NativeAccountState, URL) -> Bool = { state, file in
            (try? NativeAccountStore.save(state, to: file)) != nil
        }
    ) {
        self.stateFile = stateFile
        self.diagnosticLog = diagnosticLog
        self.readVaultBackup = readVaultBackup
        self.writeVaultBackup = writeVaultBackup
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

        guard let backup = readVaultBackup(account.id) else {
            writeDiagnostic("switch to \(account.id) failed: no backup credentials found")
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

        guard writeLiveCredentials(backup.liveCredentials) else {
            writeDiagnostic("switch to \(account.id) failed: could not write live credentials")
            return false
        }

        guard writeLiveOauthBlock(backup.oauthAccountBlock) else {
            _ = writeLiveCredentials(currentLiveCredentials)
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
    /// opaque JSON sub-object exactly as cux does — this app never
    /// interprets its fields except via `AccountDiscovery.emailAddress(from:)`
    /// / `.organizationUuid(from:)` when capturing a brand-new login.
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
