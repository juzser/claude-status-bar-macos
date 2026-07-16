import Foundation
import Testing
@testable import StatusBarCore

@Suite struct NativeAccountStoreTests {
    @Test func existsIsFalseForMissingFile() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        #expect(NativeAccountStore.exists(file: file) == false)
    }

    @Test func loadReturnsEmptyStateWhenFileMissing() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let state = NativeAccountStore.load(file: file)
        #expect(state.activeId == nil)
        #expect(state.accounts.isEmpty)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }

        let account = NativeAccount(id: "native-0", alias: "Work", email: "dev@example.com",
                                    slot: 0, organizationUuid: "org-1", needsRelogin: false)
        let state = NativeAccountState(activeId: "native-0", accounts: [account])
        try NativeAccountStore.save(state, to: file)

        #expect(NativeAccountStore.exists(file: file))
        let loaded = NativeAccountStore.load(file: file)
        #expect(loaded == state)
    }

    @Test func nextSlotIsOneMoreThanHighestExisting() {
        let state = NativeAccountState(activeId: nil, accounts: [
            NativeAccount(id: "a", alias: nil, email: nil, slot: 0, organizationUuid: nil, needsRelogin: false),
            NativeAccount(id: "b", alias: nil, email: nil, slot: 2, organizationUuid: nil, needsRelogin: false),
        ])
        #expect(NativeAccountStore.nextSlot(in: state) == 3)
    }

    @Test func nextSlotIsZeroWhenEmpty() {
        #expect(NativeAccountStore.nextSlot(in: NativeAccountState()) == 0)
    }

    @Test func toAccountMarksActiveIdAsActive() {
        let account = NativeAccount(id: "native-1", alias: nil, email: "a@b.com",
                                    slot: 1, organizationUuid: "org-1", needsRelogin: true)
        let state = NativeAccountState(activeId: "native-1", accounts: [account])
        let converted = NativeAccountStore.toAccount(account, state: state)
        #expect(converted.id == "native-1")
        #expect(converted.isActive)
        #expect(converted.slot == 1)
        #expect(converted.oauthURL == URL(fileURLWithPath: "/dev/null"))
    }

    @Test func toAccountsSortsBySlot() {
        let state = NativeAccountState(activeId: "b", accounts: [
            NativeAccount(id: "b", alias: nil, email: nil, slot: 1, organizationUuid: nil, needsRelogin: false),
            NativeAccount(id: "a", alias: nil, email: nil, slot: 0, organizationUuid: nil, needsRelogin: false),
        ])
        let accounts = NativeAccountStore.toAccounts(state)
        #expect(accounts.map(\.id) == ["a", "b"])
        #expect(accounts.map(\.isActive) == [false, true])
    }
}
