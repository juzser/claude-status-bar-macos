import Foundation
import Testing
@testable import StatusBarCore

@Suite struct TokenSlayerMappingTests {
    private func makeAccount(
        index: Int = 1, name: String = "work", alias: String? = "w", email: String? = "a@x.com",
        orgUuid: String? = "o1", uuid: String? = "u1", active: Bool = true, state: String = "active",
        usage: SlayerUsage? = nil
    ) -> SlayerAccount {
        SlayerAccount(index: index, name: name, alias: alias, email: email, orgUuid: orgUuid,
                      uuid: uuid, plan: "claude_max", active: active, state: state, usage: usage)
    }

    // MARK: - accountId

    @Test func accountIdPrefersUuidOverName() {
        let account = makeAccount(name: "work", uuid: "u1")
        #expect(TokenSlayerMapping.accountId(for: account) == "u1")
    }

    @Test func accountIdFallsBackToNameWhenUuidNil() {
        let account = makeAccount(name: "work", uuid: nil)
        #expect(TokenSlayerMapping.accountId(for: account) == "work")
    }

    // MARK: - account(from:)

    @Test func mapsAccountFieldsFromSlayerAccount() {
        let slayer = makeAccount(index: 3, name: "work", alias: "w", email: "a@x.com",
                                 orgUuid: "o1", uuid: "u1", active: true)
        let account = TokenSlayerMapping.account(from: slayer)
        #expect(account.id == "u1")
        #expect(account.alias == "w")
        #expect(account.email == "a@x.com")
        #expect(account.slot == 3)
        #expect(account.isActive == true)
        #expect(account.organizationUuid == "o1")
        #expect(account.oauthURL == URL(fileURLWithPath: "/dev/null"))
    }

    @Test func mapsInactiveAccountAsNotActive() {
        let slayer = makeAccount(active: false)
        #expect(TokenSlayerMapping.account(from: slayer).isActive == false)
    }

    // MARK: - usageState(from:) — needsRelogin

    @Test func needsReloginWhenStateIsExpired() {
        let slayer = makeAccount(state: "expired", usage: nil)
        #expect(TokenSlayerMapping.usageState(from: slayer).needsRelogin == true)
    }

    @Test func needsReloginWhenUsageReportsTokenExpired() {
        let usage = SlayerUsage(fiveHour: nil, sevenDay: nil, polledAt: nil, tokenExpired: true)
        let slayer = makeAccount(state: "active", usage: usage)
        #expect(TokenSlayerMapping.usageState(from: slayer).needsRelogin == true)
    }

    @Test func doesNotNeedReloginWhenActiveAndTokenNotExpired() {
        let usage = SlayerUsage(fiveHour: nil, sevenDay: nil, polledAt: nil, tokenExpired: false)
        let slayer = makeAccount(state: "active", usage: usage)
        #expect(TokenSlayerMapping.usageState(from: slayer).needsRelogin == false)
    }

    @Test func doesNotNeedReloginWhenUsageIsNilAndStateIsNotExpired() {
        let slayer = makeAccount(state: "ready", usage: nil)
        #expect(TokenSlayerMapping.usageState(from: slayer).needsRelogin == false)
    }

    // MARK: - usageState(from:) — freshness + snapshot mapping

    @Test func freshnessIsNoneWhenUsageIsNil() {
        let slayer = makeAccount(usage: nil)
        let state = TokenSlayerMapping.usageState(from: slayer)
        #expect(state.freshness == .none)
        #expect(state.snapshot == nil)
    }

    @Test func freshnessIsFreshWhenUsageIsPresentRegardlessOfLiveness() {
        // Both `list --json` (cached) and `status --json` (live) map to
        // `.fresh` — see TokenSlayerMapping's doc comment for why.
        let usage = SlayerUsage(fiveHour: nil, sevenDay: nil, polledAt: nil, tokenExpired: false)
        let slayer = makeAccount(usage: usage)
        #expect(TokenSlayerMapping.usageState(from: slayer).freshness == .fresh)
    }

    @Test func mapsUsageWindowsIntoUsageSnapshot() {
        let usage = SlayerUsage(
            fiveHour: SlayerUsageWindow(utilization: 42.0, resetsAt: Date(timeIntervalSince1970: 100)),
            sevenDay: SlayerUsageWindow(utilization: 18.0, resetsAt: Date(timeIntervalSince1970: 200)),
            polledAt: Date(timeIntervalSince1970: 50),
            tokenExpired: false
        )
        let slayer = makeAccount(usage: usage)
        let snapshot = TokenSlayerMapping.usageState(from: slayer).snapshot
        #expect(snapshot?.fiveHour?.utilization == 42.0)
        #expect(snapshot?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 100))
        #expect(snapshot?.sevenDay?.utilization == 18.0)
        #expect(snapshot?.sevenDay?.resetsAt == Date(timeIntervalSince1970: 200))
        #expect(snapshot?.fetchedAt == Date(timeIntervalSince1970: 50))
    }

    @Test func fetchedAtFallsBackToNowWhenPolledAtIsNil() {
        let usage = SlayerUsage(fiveHour: nil, sevenDay: nil, polledAt: nil, tokenExpired: false)
        let slayer = makeAccount(usage: usage)
        let before = Date()
        let snapshot = TokenSlayerMapping.usageState(from: slayer).snapshot
        #expect(snapshot?.fetchedAt ?? .distantPast >= before)
    }

    // MARK: - dedupedById

    @Test func dedupedByIdKeepsLastAccountWhenIdsCollide() {
        // Two slots can legitimately share a `uuid` (e.g. re-adding an
        // account under a new name while an old slot still exists) — the
        // CLI's own list order determines which one wins, matching how
        // `Dictionary(_:uniquingKeysWith:)` last-wins merges would behave.
        let stale = makeAccount(index: 0, name: "work-old", uuid: "u1")
        let fresh = makeAccount(index: 1, name: "work-new", uuid: "u1")
        let deduped = TokenSlayerMapping.dedupedById([stale, fresh])
        #expect(deduped.count == 1)
        #expect(deduped.first?.name == "work-new")
    }

    @Test func dedupedByIdPreservesNonCollidingAccountsInOrder() {
        let a = makeAccount(index: 0, name: "a", uuid: "u1")
        let b = makeAccount(index: 1, name: "b", uuid: "u2")
        let deduped = TokenSlayerMapping.dedupedById([a, b])
        #expect(deduped.map(\.name) == ["a", "b"])
    }
}
