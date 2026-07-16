import Foundation

/// Detects a completed `claude /login` by diffing the live credentials
/// Keychain item against a baseline snapshotted right before the login was
/// launched. Polled from `AppState` on popover-open and on a ~60s ticker
/// (see `AppState.recheckReloginAccounts()`); a no-op whenever no capture
/// is in progress.
public actor AccountCapture {
    public enum Result: Equatable, Sendable {
        case noChange
        case captured(Account)
    }

    private var baseline: CredentialBackup?
    private let storeFile: URL
    private let readLiveCredentials: () -> Data?
    private let readLiveOauthBlock: () -> Data?
    private let vaultWrite: (String, CredentialBackup) -> Bool
    private let loadState: (URL) -> NativeAccountState
    private let saveState: (NativeAccountState, URL) -> Bool

    public init(
        storeFile: URL,
        readLiveCredentials: @escaping () -> Data? = { LiveCredentialWriter.read() },
        readLiveOauthBlock: @escaping () -> Data? = { NativeAccountSwitcher.defaultReadLiveOauthBlock() },
        vaultWrite: @escaping (String, CredentialBackup) -> Bool = { AccountCredentialVault.write(accountId: $0, $1) },
        loadState: @escaping (URL) -> NativeAccountState = NativeAccountStore.load,
        saveState: @escaping (NativeAccountState, URL) -> Bool = { state, file in
            (try? NativeAccountStore.save(state, to: file)) != nil
        }
    ) {
        self.storeFile = storeFile
        self.readLiveCredentials = readLiveCredentials
        self.readLiveOauthBlock = readLiveOauthBlock
        self.vaultWrite = vaultWrite
        self.loadState = loadState
        self.saveState = saveState
    }

    /// Snapshots the currently-live credentials as the "before" baseline.
    /// Call right before launching `claude /login` in Terminal.
    public func beginCapture() {
        guard let creds = readLiveCredentials() else { baseline = nil; return }
        baseline = CredentialBackup(liveCredentials: creds, oauthAccountBlock: readLiveOauthBlock())
    }

    /// Polls the live Keychain item; if it differs from the baseline, a new
    /// login has completed. Registers the new account — and, on a
    /// first-ever capture with an empty store, the pre-capture baseline
    /// account too — into `NativeAccountStore`.
    public func checkForNewLogin() -> Result {
        guard let baseline, let currentCreds = readLiveCredentials(),
              currentCreds != baseline.liveCredentials else { return .noChange }

        var state = loadState(storeFile)
        let currentOauth = readLiveOauthBlock()

        if state.accounts.isEmpty {
            let baselineSlot = NativeAccountStore.nextSlot(in: state)
            let baselineId = "native-\(baselineSlot)"
            _ = vaultWrite(baselineId, baseline)
            state.accounts.append(NativeAccount(
                id: baselineId, alias: nil,
                email: baseline.oauthAccountBlock.flatMap(AccountDiscovery.emailAddress(from:)),
                slot: baselineSlot,
                organizationUuid: baseline.oauthAccountBlock.flatMap(AccountDiscovery.organizationUuid(from:)),
                needsRelogin: false))
            state.activeId = baselineId
        }

        let newSlot = NativeAccountStore.nextSlot(in: state)
        let newId = "native-\(newSlot)"
        let newBackup = CredentialBackup(liveCredentials: currentCreds, oauthAccountBlock: currentOauth)
        _ = vaultWrite(newId, newBackup)
        let newAccount = NativeAccount(
            id: newId, alias: nil,
            email: currentOauth.flatMap(AccountDiscovery.emailAddress(from:)),
            slot: newSlot,
            organizationUuid: currentOauth.flatMap(AccountDiscovery.organizationUuid(from:)),
            needsRelogin: false)
        state.accounts.append(newAccount)
        state.activeId = newId
        self.baseline = nil

        guard saveState(state, storeFile) else { return .noChange }
        return .captured(NativeAccountStore.toAccount(newAccount, state: state))
    }
}
