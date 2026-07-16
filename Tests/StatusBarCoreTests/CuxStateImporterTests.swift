import Foundation
import Testing
@testable import StatusBarCore

@Suite struct CuxStateImporterTests {
    private func makeCuxRoot(accounts: [(slot: Int, email: String, alias: String?, oauthJSON: String?)],
                             activeSlot: Int?) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountsDir = root.appendingPathComponent("accounts", isDirectory: true)
        try! FileManager.default.createDirectory(at: accountsDir, withIntermediateDirectories: true)

        var accountsJSON = "{"
        accountsJSON += accounts.map { acct in
            let aliasField = acct.alias.map { "\"\($0)\"" } ?? "null"
            return "\"\(acct.slot)\":{\"slot\":\(acct.slot),\"email\":\"\(acct.email)\",\"alias\":\(aliasField)}"
        }.joined(separator: ",")
        accountsJSON += "}"
        let activeSlotJSON = activeSlot.map(String.init) ?? "null"
        let stateJSON = "{\"activeSlot\":\(activeSlotJSON),\"accounts\":\(accountsJSON)}"
        try! Data(stateJSON.utf8).write(to: root.appendingPathComponent("state.json"))

        for acct in accounts {
            let dirName = String(format: "%02d-%@", acct.slot, acct.email)
            let dir = accountsDir.appendingPathComponent(dirName, isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let oauthJSON = acct.oauthJSON {
                try! Data(oauthJSON.utf8).write(to: dir.appendingPathComponent("oauth.json"))
            }
        }
        return root
    }

    @Test func doesNothingIfNativeStateFileAlreadyExists() {
        let cuxRoot = makeCuxRoot(accounts: [(0, "a@example.com", nil, "{}")], activeSlot: 0)
        let nativeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try! Data("{}".utf8).write(to: nativeFile)
        defer { try? FileManager.default.removeItem(at: nativeFile) }

        CuxStateImporter.importIfNeeded(cuxRoot: cuxRoot, nativeStateFile: nativeFile, vaultWrite: { _, _ in true },
                                        keychainReader: { _ in Data("mock".utf8) })

        let raw = try! String(contentsOf: nativeFile, encoding: .utf8)
        #expect(raw == "{}")
    }

    @Test func doesNothingWhenNoCuxAccountsExist() {
        let cuxRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nativeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: nativeFile) }

        CuxStateImporter.importIfNeeded(cuxRoot: cuxRoot, nativeStateFile: nativeFile, vaultWrite: { _, _ in true },
                                        keychainReader: { _ in Data("mock".utf8) })

        #expect(NativeAccountStore.exists(file: nativeFile) == false)
    }

    @Test func importsAllAccountsAndMarksActiveOne() {
        let cuxRoot = makeCuxRoot(accounts: [
            (0, "a@example.com", "Work", "{\"organizationUuid\":\"org-a\"}"),
            (1, "b@example.com", nil, "{\"organizationUuid\":\"org-b\"}"),
        ], activeSlot: 1)
        let nativeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: nativeFile) }

        CuxStateImporter.importIfNeeded(cuxRoot: cuxRoot, nativeStateFile: nativeFile, vaultWrite: { _, _ in true },
                                        keychainReader: { _ in Data("mock".utf8) })

        let state = NativeAccountStore.load(file: nativeFile)
        #expect(state.accounts.count == 2)
        #expect(state.activeId == "slot-1")
        #expect(state.accounts.first { $0.id == "slot-0" }?.alias == "Work")
        #expect(state.accounts.first { $0.id == "slot-0" }?.organizationUuid == "org-a")
        #expect(state.accounts.allSatisfy { $0.needsRelogin == false })
    }

    @Test func oneUnreadableAccountDoesNotBlockImportingTheRest() {
        // Slot 0 has no cux-backup Keychain entry (simulated via vaultWrite
        // failing only for that account) — it should still be imported,
        // just flagged needsRelogin.
        let cuxRoot = makeCuxRoot(accounts: [
            (0, "a@example.com", nil, "{}"),
            (1, "b@example.com", nil, "{}"),
        ], activeSlot: 0)
        let nativeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: nativeFile) }

        CuxStateImporter.importIfNeeded(cuxRoot: cuxRoot, nativeStateFile: nativeFile, vaultWrite: { id, _ in
            id != "slot-0"
        }, keychainReader: { _ in Data("mock".utf8) })

        let state = NativeAccountStore.load(file: nativeFile)
        #expect(state.accounts.count == 2)
        #expect(state.accounts.first { $0.id == "slot-0" }?.needsRelogin == true)
        #expect(state.accounts.first { $0.id == "slot-1" }?.needsRelogin == false)
    }
}
