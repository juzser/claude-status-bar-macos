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

    /// Minor review finding m1: the default `vaultSelfHeal` closure used to
    /// call `AccountVaultSelfHeal.run(accountId:)` with no `diagnosticLog` at
    /// all, so switch-path heals went completely unlogged — the one thing
    /// `native-switch.log` exists to capture. Uses a real, guaranteed-unique
    /// account id (same "route through the real non-interactive default
    /// against a presumably-absent item" pattern as
    /// `AccountCredentialVaultTests.defaultReaderCompilesAndReturnsNilForAbsentTestItem`)
    /// so this exercises the actual default wiring, not an override, without
    /// risking a collision with any real backup item on the machine running
    /// the test. Asserts on the "vault self-heal" substring specifically —
    /// only `AccountVaultSelfHeal.run`'s own diagnostic lines contain that
    /// phrase, so this can't pass merely because `switchTo`'s unrelated
    /// failure diagnostic happens to also mention the account id.
    @Test func defaultVaultSelfHealLogsToSwitchersOwnDiagnosticLog() async throws {
        let uniqueId = "vault-self-heal-log-test-\(UUID().uuidString)"
        let state = NativeAccountState(activeId: "native-0", accounts: [
            NativeAccount(id: "native-0", alias: nil, email: "a@example.com", slot: 0,
                         organizationUuid: "org-a", needsRelogin: false),
            NativeAccount(id: uniqueId, alias: nil, email: "b@example.com", slot: 1,
                         organizationUuid: "org-b", needsRelogin: false),
        ])
        let logFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-switch-test-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logFile) }

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: logFile,
            readVaultBackup: { _ in nil },
            writeVaultBackup: { _, _ in false },
            readLiveCredentials: { nil },
            writeLiveCredentials: { _ in false },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in false },
            loadState: { _ in state },
            saveState: { _, _ in false }
            // vaultSelfHeal deliberately not overridden — exercising the
            // actual default closure this test is about.
        )
        _ = await switcher.switchTo(account: account(uniqueId, state: state))

        let logContents = try String(contentsOf: logFile, encoding: .utf8)
        #expect(logContents.contains("vault self-heal"))
    }

    /// Minor review finding m2: the backup-read-miss diagnostic used to just
    /// say "no backup credentials found" with no indication of why. Enriched
    /// with the real `KeychainStatus` via a new injectable
    /// `readVaultBackupStatus` param.
    @Test func backupReadMissDiagnosticIncludesKeychainStatus() async throws {
        let state = makeState()
        let logFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-switch-test-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logFile) }

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: logFile,
            readVaultBackup: { _ in nil },
            readVaultBackupStatus: { _ in .interactionNotAllowed },
            writeVaultBackup: { _, _ in false },
            readLiveCredentials: { nil },
            writeLiveCredentials: { _ in false },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in false },
            loadState: { _ in state },
            saveState: { _, _ in false },
            vaultSelfHeal: { _ in true }
        )
        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result == false)

        let logContents = try String(contentsOf: logFile, encoding: .utf8)
        #expect(logContents.contains("interactionNotAllowed"))
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

    // MARK: - Deriving the true live owner from live state

    /// Builds a fake ~/.claude.json "oauthAccount" block Data, matching the
    /// shape `AccountDiscovery.organizationUuid(from:)` /
    /// `.emailAddress(from:)` parse.
    private func oauthBlock(organizationUuid: String? = nil, email: String? = nil) -> Data {
        var obj: [String: Any] = [:]
        if let organizationUuid { obj["organizationUuid"] = organizationUuid }
        if let email { obj["emailAddress"] = email }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    /// Reproduces the token-slayer divergence bug's failure mode #1: stored
    /// `activeId` says "native-0" is active, but the live oauthAccount block
    /// actually identifies "native-1" (org-b) as the true owner — e.g.
    /// because token-slayer switched live credentials without ever touching
    /// native-accounts.json. Switching to "native-0" (what the stale pointer
    /// already claims is active) must NOT silently no-op: the live
    /// credentials really belong to native-1, so this has to be a real
    /// switch.
    @Test func staleStoredActiveIdDoesNotMaskARealSwitch() async {
        let state = makeState()
        var vault: [String: CredentialBackup] = [
            "native-0": CredentialBackup(liveCredentials: Data("native-0-creds".utf8), oauthAccountBlock: nil),
        ]
        var liveCredentials = Data("actually-native-1s-creds".utf8)
        var writeLiveCalled = false

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { vault[$0] },
            writeVaultBackup: { id, backup in vault[id] = backup; return true },
            readLiveCredentials: { liveCredentials },
            writeLiveCredentials: { data in writeLiveCalled = true; liveCredentials = data; return true },
            readLiveOauthBlock: { self.oauthBlock(organizationUuid: "org-b", email: "b@example.com") },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-0", state: state))

        #expect(result)
        #expect(writeLiveCalled)
        #expect(liveCredentials == Data("native-0-creds".utf8))
    }

    /// Failure mode #2, the data-loss one: with the same stale-pointer setup
    /// as above, the live credentials being displaced must be backed up
    /// under their *true* owner (native-1, derived from the live
    /// oauthAccount block) — not under the stale stored activeId
    /// (native-0), which would silently overwrite native-0's own vault entry
    /// with native-1's credentials.
    @Test func outgoingBackupGoesToDerivedOwnerNotStaleStoredActiveId() async {
        let state = makeState()
        var vault: [String: CredentialBackup] = [
            "native-0": CredentialBackup(liveCredentials: Data("native-0-original".utf8), oauthAccountBlock: nil),
        ]
        let liveCredentials = Data("actually-native-1s-creds".utf8)

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("native-0-target".utf8), oauthAccountBlock: nil) },
            writeVaultBackup: { id, backup in vault[id] = backup; return true },
            readLiveCredentials: { liveCredentials },
            writeLiveCredentials: { _ in true },
            readLiveOauthBlock: { self.oauthBlock(organizationUuid: "org-b", email: "b@example.com") },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-0", state: state))

        #expect(result)
        // native-1 (the real owner of the displaced live credentials) gets
        // the backup...
        #expect(vault["native-1"]?.liveCredentials == liveCredentials)
        // ...and native-0's own vault entry (its true stored backup) must be
        // left completely untouched.
        #expect(vault["native-0"]?.liveCredentials == Data("native-0-original".utf8))
    }

    /// When the live oauthAccount block positively identifies an owner that
    /// happens to already match the stored activeId, behaviour is exactly
    /// the pre-existing happy path: the guard fires against the (now
    /// confirmed, not just assumed) stored id.
    @Test func identifiedLiveOwnerMatchingStoredActiveIdBehavesLikeUnchangedHappyPath() async {
        let state = makeState()
        var vault: [String: CredentialBackup] = [:]

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("target".utf8), oauthAccountBlock: nil) },
            writeVaultBackup: { id, backup in vault[id] = backup; return true },
            readLiveCredentials: { Data("current".utf8) },
            writeLiveCredentials: { _ in true },
            readLiveOauthBlock: { self.oauthBlock(organizationUuid: "org-a", email: "a@example.com") },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))

        #expect(result)
        #expect(vault["native-0"]?.liveCredentials == Data("current".utf8))
    }

    /// A live oauthAccount block can also identify the owner by email alone
    /// (no organizationUuid field) — the same fallback order
    /// `AccountCapture.matchingIndex` already uses.
    @Test func identifiesLiveOwnerByEmailWhenOrganizationUuidAbsent() async {
        let state = makeState()
        var vault: [String: CredentialBackup] = [:]

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("native-0-target".utf8), oauthAccountBlock: nil) },
            writeVaultBackup: { id, backup in vault[id] = backup; return true },
            readLiveCredentials: { Data("actually-native-1s-creds".utf8) },
            writeLiveCredentials: { _ in true },
            readLiveOauthBlock: { self.oauthBlock(email: "b@example.com") },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-0", state: state))

        #expect(result)
        #expect(vault["native-1"]?.liveCredentials == Data("actually-native-1s-creds".utf8))
    }

    /// The live oauthAccount block positively identifies an org uuid/email
    /// that matches no tracked account at all — e.g. the live login belongs
    /// to some account this app never captured. Guessing which vault entry
    /// to overwrite here would risk destroying an unrelated account's
    /// backup, so this must abort outright rather than fall back to the
    /// stale stored activeId.
    @Test func unidentifiableLiveOwnerAbortsWithoutWritingAnyVaultBackup() async {
        let state = makeState()
        var writeVaultBackupCalled = false
        var writeLiveCalled = false

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("target".utf8), oauthAccountBlock: nil) },
            writeVaultBackup: { _, _ in writeVaultBackupCalled = true; return true },
            readLiveCredentials: { Data("current".utf8) },
            writeLiveCredentials: { _ in writeLiveCalled = true; return true },
            readLiveOauthBlock: { self.oauthBlock(organizationUuid: "org-unknown", email: "unknown@example.com") },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))

        #expect(result == false)
        #expect(writeVaultBackupCalled == false)
        #expect(writeLiveCalled == false)
    }

    /// Two tracked accounts sharing the same organizationUuid (a corrupted
    /// native-accounts.json) makes the live owner ambiguous even though the
    /// live block positively matches *something*. Same abort-don't-guess
    /// contract as the fully-unidentifiable case.
    @Test func ambiguousLiveOwnerAcrossAccountsAbortsWithoutWritingAnyVaultBackup() async {
        var state = makeState()
        state.accounts[1].organizationUuid = "org-a" // now both accounts share "org-a"
        var writeVaultBackupCalled = false

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("target".utf8), oauthAccountBlock: nil) },
            writeVaultBackup: { _, _ in writeVaultBackupCalled = true; return true },
            readLiveCredentials: { Data("current".utf8) },
            writeLiveCredentials: { _ in true },
            readLiveOauthBlock: { self.oauthBlock(organizationUuid: "org-a") },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))

        #expect(result == false)
        #expect(writeVaultBackupCalled == false)
    }

    /// Diagnostic-log coverage for the abort path: the message must explain
    /// *why* the switch refused, not just that it failed silently.
    @Test func unidentifiableLiveOwnerWritesExplanatoryDiagnostic() async throws {
        let state = makeState()
        let logFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-switch-test-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logFile) }

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: logFile,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("target".utf8), oauthAccountBlock: nil) },
            writeVaultBackup: { _, _ in true },
            readLiveCredentials: { Data("current".utf8) },
            writeLiveCredentials: { _ in true },
            readLiveOauthBlock: { self.oauthBlock(organizationUuid: "org-unknown") },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result == false)

        let logContents = try String(contentsOf: logFile, encoding: .utf8)
        #expect(logContents.contains("could not verify") || logContents.contains("cannot verify") || logContents.contains("ambiguous") || logContents.contains("live owner") || logContents.contains("no tracked account"))
    }
}
