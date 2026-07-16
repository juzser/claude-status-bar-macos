import Foundation
import Testing
@testable import StatusBarCore

@Suite struct AccountCaptureTests {
    private func makeCapture(
        storeFile: URL,
        liveCredentials: @escaping () -> Data?,
        liveOauthBlock: @escaping () -> Data?,
        vault: inout [String: CredentialBackup]
    ) -> (AccountCapture, () -> [String: CredentialBackup]) {
        var storage = vault
        let capture = AccountCapture(
            storeFile: storeFile,
            readLiveCredentials: liveCredentials,
            readLiveOauthBlock: liveOauthBlock,
            vaultWrite: { id, backup in storage[id] = backup; return true },
            loadState: NativeAccountStore.load,
            saveState: { state, file in (try? NativeAccountStore.save(state, to: file)) != nil }
        )
        vault = storage
        return (capture, { storage })
    }

    @Test func checkForNewLoginIsNoOpWithoutABaseline() async {
        let storeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        var vault: [String: CredentialBackup] = [:]
        let (capture, _) = makeCapture(storeFile: storeFile,
                                       liveCredentials: { Data("anything".utf8) },
                                       liveOauthBlock: { nil }, vault: &vault)

        let result = await capture.checkForNewLogin()
        if case .noChange = result {} else { Issue.record("expected .noChange") }
    }

    @Test func checkForNewLoginIsNoOpWhenCredentialsUnchanged() async {
        let storeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        var vault: [String: CredentialBackup] = [:]
        let (capture, _) = makeCapture(storeFile: storeFile,
                                       liveCredentials: { Data("same".utf8) },
                                       liveOauthBlock: { nil }, vault: &vault)

        await capture.beginCapture()
        let result = await capture.checkForNewLogin()
        if case .noChange = result {} else { Issue.record("expected .noChange") }
    }

    @Test func firstEverAddAccountBootstrapsBaselineAndNewAccount() async {
        let storeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: storeFile) }

        var live = Data("old-creds".utf8)
        var oauth: Data? = Data(#"{"emailAddress":"old@example.com","organizationUuid":"org-old"}"#.utf8)
        var vault: [String: CredentialBackup] = [:]
        let (capture, vaultSnapshot) = makeCapture(storeFile: storeFile,
                                                   liveCredentials: { live },
                                                   liveOauthBlock: { oauth }, vault: &vault)

        await capture.beginCapture()
        // Simulate the browser hand-off completing with a new login.
        live = Data("new-creds".utf8)
        oauth = Data(#"{"emailAddress":"new@example.com","organizationUuid":"org-new"}"#.utf8)

        let result = await capture.checkForNewLogin()
        guard case .captured(let newAccount) = result else {
            Issue.record("expected .captured"); return
        }

        let state = NativeAccountStore.load(file: storeFile)
        #expect(state.accounts.count == 2)
        #expect(state.accounts.first { $0.slot == 0 }?.email == "old@example.com")
        #expect(state.accounts.first { $0.slot == 1 }?.email == "new@example.com")
        #expect(state.activeId == newAccount.id)
        #expect(newAccount.isActive)
        #expect(vaultSnapshot().count == 2)
    }

    @Test func subsequentAddAccountOnlyRegistersTheNewOne() async {
        let storeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: storeFile) }

        let existing = NativeAccountState(activeId: "native-0", accounts: [
            NativeAccount(id: "native-0", alias: nil, email: "old@example.com", slot: 0,
                         organizationUuid: "org-old", needsRelogin: false),
        ])
        try! NativeAccountStore.save(existing, to: storeFile)

        var live = Data("old-creds".utf8)
        var oauth: Data? = nil
        var vault: [String: CredentialBackup] = [:]
        let (capture, _) = makeCapture(storeFile: storeFile, liveCredentials: { live },
                                       liveOauthBlock: { oauth }, vault: &vault)

        await capture.beginCapture()
        live = Data("new-creds".utf8)
        oauth = Data(#"{"emailAddress":"new@example.com","organizationUuid":"org-new"}"#.utf8)

        let result = await capture.checkForNewLogin()
        guard case .captured = result else { Issue.record("expected .captured"); return }

        let state = NativeAccountStore.load(file: storeFile)
        #expect(state.accounts.count == 2)
        #expect(state.accounts.first { $0.slot == 1 }?.email == "new@example.com")
        #expect(state.activeId == "native-1")
    }
}
