import Foundation
import Testing
@testable import StatusBarCore

@Suite struct NativeAccountSwitcherTests {
    private func makeState() -> NativeAccountState {
        NativeAccountState(activeId: "native-0", accounts: [
            NativeAccount(id: "native-0", alias: nil, email: "a@example.com", slot: 0,
                         organizationUuid: "org-a", needsRelogin: false),
            NativeAccount(id: "native-1", alias: nil, email: "b@example.com", slot: 1,
                         organizationUuid: "org-b", needsRelogin: false),
        ])
    }

    private func account(_ id: String, state: NativeAccountState) -> Account {
        NativeAccountStore.toAccount(state.accounts.first { $0.id == id }!, state: state)
    }

    @Test func switchingToAlreadyActiveAccountIsHarmlessNoOp() async {
        let state = makeState()
        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in nil },
            writeVaultBackup: { _, _ in false },
            readLiveCredentials: { nil },
            writeLiveCredentials: { _ in false },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in false },
            loadState: { _ in state },
            saveState: { _, _ in false }
        )
        let result = await switcher.switchTo(account: account("native-0", state: state))
        #expect(result)
    }

    @Test func fullSuccessSwapsCredentialsAndUpdatesState() async {
        let state = makeState()
        var vault: [String: CredentialBackup] = [
            "native-1": CredentialBackup(liveCredentials: Data("target-creds".utf8),
                                         oauthAccountBlock: Data("target-oauth".utf8)),
        ]
        var liveCredentials = Data("current-creds".utf8)
        var liveOauthBlock: Data? = Data("current-oauth".utf8)
        var savedState: NativeAccountState?

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { vault[$0] },
            writeVaultBackup: { id, backup in vault[id] = backup; return true },
            readLiveCredentials: { liveCredentials },
            writeLiveCredentials: { data in liveCredentials = data; return true },
            readLiveOauthBlock: { liveOauthBlock },
            writeLiveOauthBlock: { data in liveOauthBlock = data; return true },
            loadState: { _ in state },
            saveState: { newState, _ in savedState = newState; return true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))

        #expect(result)
        #expect(liveCredentials == Data("target-creds".utf8))
        #expect(liveOauthBlock == Data("target-oauth".utf8))
        #expect(savedState?.activeId == "native-1")
        #expect(vault["native-0"]?.liveCredentials == Data("current-creds".utf8))
        #expect(vault["native-0"]?.oauthAccountBlock == Data("current-oauth".utf8))
    }

    @Test func backupReadFailureAbortsBeforeAnyLiveWrite() async {
        let state = makeState()
        var liveCredentials = Data("current-creds".utf8)
        var writeLiveCalled = false

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in nil },
            writeVaultBackup: { _, _ in true },
            readLiveCredentials: { liveCredentials },
            writeLiveCredentials: { data in writeLiveCalled = true; liveCredentials = data; return true },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result == false)
        #expect(writeLiveCalled == false)
    }

    @Test func backupOfOutgoingAccountFailureAbortsBeforeLiveWrite() async {
        let state = makeState()
        var writeLiveCalled = false
        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("target".utf8), oauthAccountBlock: nil) },
            writeVaultBackup: { _, _ in false },
            readLiveCredentials: { Data("current".utf8) },
            writeLiveCredentials: { _ in writeLiveCalled = true; return true },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result == false)
        #expect(writeLiveCalled == false)
    }

    @Test func liveCredentialsWriteFailureAbortsWithoutRollback() async {
        let state = makeState()
        var liveCredentials = Data("current".utf8)
        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("target".utf8), oauthAccountBlock: nil) },
            writeVaultBackup: { _, _ in true },
            readLiveCredentials: { liveCredentials },
            writeLiveCredentials: { _ in false },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result == false)
        // Nothing was ever overwritten live, so there's nothing to roll back —
        // the pre-switch value must be exactly what it was before the call.
        #expect(liveCredentials == Data("current".utf8))
    }

    @Test func oauthBlockWriteFailureRollsBackCredentialsAndOauthBlock() async {
        let state = makeState()
        var liveCredentials = Data("current-creds".utf8)
        var liveOauthBlock: Data? = Data("current-oauth".utf8)

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("target-creds".utf8),
                                                     oauthAccountBlock: Data("target-oauth".utf8)) },
            writeVaultBackup: { _, _ in true },
            readLiveCredentials: { liveCredentials },
            writeLiveCredentials: { data in liveCredentials = data; return true },
            readLiveOauthBlock: { liveOauthBlock },
            writeLiveOauthBlock: { data in
                if data == Data("target-oauth".utf8) { return false }
                liveOauthBlock = data
                return true
            },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result == false)
        #expect(liveCredentials == Data("current-creds".utf8))
        #expect(liveOauthBlock == Data("current-oauth".utf8))
    }

    /// Finding #2's other half: `readVaultBackup` (via `AccountCredentialVault
    /// .defaultReader`) is now non-interactive, so a switch to an account
    /// whose vault item isn't yet trusted would otherwise just fail outright.
    /// `switchTo` runs `vaultSelfHeal` for the *target* account first so
    /// trust gets (re-)established, on a controlled and logged path, before
    /// the backup read that actually needs it.
    @Test func vaultSelfHealRunsForTargetAccountBeforeReadingBackup() async {
        let state = makeState()
        var selfHealedAccountId: String?
        var readVaultBackupCalledAfterSelfHeal = false

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { id in
                readVaultBackupCalledAfterSelfHeal = (selfHealedAccountId == id)
                return CredentialBackup(liveCredentials: Data("target".utf8), oauthAccountBlock: nil)
            },
            writeVaultBackup: { _, _ in true },
            readLiveCredentials: { Data("current".utf8) },
            writeLiveCredentials: { _ in true },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true },
            vaultSelfHeal: { id in selfHealedAccountId = id; return true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result)
        #expect(selfHealedAccountId == "native-1")
        #expect(readVaultBackupCalledAfterSelfHeal)
    }

    @Test func vaultSelfHealDoesNotRunForAlreadyActiveAccountNoOp() async {
        let state = makeState()
        var selfHealCalled = false
        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in nil },
            writeVaultBackup: { _, _ in false },
            readLiveCredentials: { nil },
            writeLiveCredentials: { _ in false },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in false },
            loadState: { _ in state },
            saveState: { _, _ in false },
            vaultSelfHeal: { _ in selfHealCalled = true; return true }
        )
        let result = await switcher.switchTo(account: account("native-0", state: state))
        #expect(result)
        #expect(selfHealCalled == false)
    }

    @Test func stateSaveFailureAfterSuccessfulLiveSwapReturnsFalse() async {
        let state = makeState()
        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("target".utf8), oauthAccountBlock: nil) },
            writeVaultBackup: { _, _ in true },
            readLiveCredentials: { Data("current".utf8) },
            writeLiveCredentials: { _ in true },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in false }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result == false)
    }
}
