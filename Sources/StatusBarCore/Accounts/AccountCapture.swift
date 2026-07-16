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
    /// account too — into `NativeAccountStore`. If the captured credential's
    /// identity (org uuid, falling back to email) matches an account already
    /// tracked in the store — e.g. a flagged account re-authenticated via
    /// `AppState.beginRelogin` — that existing entry is refreshed in place
    /// (new vault backup, `needsRelogin` cleared) instead of appending a
    /// duplicate row for the same account.
    public func checkForNewLogin() -> Result {
        guard let baseline, let currentCreds = readLiveCredentials(),
              currentCreds != baseline.liveCredentials else { return .noChange }

        var state = loadState(storeFile)
        let currentOauth = readLiveOauthBlock()
        let currentEmail = currentOauth.flatMap(AccountDiscovery.emailAddress(from:))
        let currentOrgUuid = currentOauth.flatMap(AccountDiscovery.organizationUuid(from:))

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

        let newBackup = CredentialBackup(liveCredentials: currentCreds, oauthAccountBlock: currentOauth)
        let resultAccount: NativeAccount
        if let matchIndex = Self.matchingIndex(in: state.accounts, organizationUuid: currentOrgUuid, email: currentEmail) {
            var updated = state.accounts[matchIndex]
            updated.needsRelogin = false
            if let currentEmail { updated.email = currentEmail }
            if let currentOrgUuid { updated.organizationUuid = currentOrgUuid }
            state.accounts[matchIndex] = updated
            _ = vaultWrite(updated.id, newBackup)
            state.activeId = updated.id
            resultAccount = updated
        } else {
            let newSlot = NativeAccountStore.nextSlot(in: state)
            let newId = "native-\(newSlot)"
            _ = vaultWrite(newId, newBackup)
            let newAccount = NativeAccount(
                id: newId, alias: nil,
                email: currentEmail,
                slot: newSlot,
                organizationUuid: currentOrgUuid,
                needsRelogin: false)
            state.accounts.append(newAccount)
            state.activeId = newId
            resultAccount = newAccount
        }

        // Only clear the baseline once the new state has actually been
        // persisted — if `saveState` fails, keeping the baseline lets the
        // next `checkForNewLogin()` poll retry the diff-and-save instead of
        // silently losing track of the completed login and forcing the user
        // to redo the whole re-login flow.
        guard saveState(state, storeFile) else { return .noChange }
        self.baseline = nil
        return .captured(NativeAccountStore.toAccount(resultAccount, state: state))
    }

    /// Finds an already-tracked account matching the just-captured
    /// credential's identity. Org uuid is checked first since it's the more
    /// stable identifier; email is a fallback for accounts/captures missing
    /// an org uuid.
    private static func matchingIndex(
        in accounts: [NativeAccount],
        organizationUuid: String?,
        email: String?
    ) -> Int? {
        if let organizationUuid, let idx = accounts.firstIndex(where: { $0.organizationUuid == organizationUuid }) {
            return idx
        }
        if let email, let idx = accounts.firstIndex(where: { $0.email == email }) {
            return idx
        }
        return nil
    }
}
