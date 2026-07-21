import Foundation
import Testing
@testable import StatusBarCore

/// Scripted fetcher: token -> result, so per-account behavior is controllable.
struct MockFetcher: UsageFetching {
    let results: [String: Result<UsageSnapshot, UsageError>]
    func fetch(token: String) async throws -> UsageSnapshot {
        switch results[token] {
        case .success(let snap): return snap
        case .failure(let err): throw err
        case nil: throw UsageError.network
        }
    }
}

private struct FailingFetcher: UsageFetching {
    func fetch(token: String) async throws -> UsageSnapshot {
        throw UsageError.network
    }
}

private func tempCacheFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
}

private func snap(_ pct: Double) -> UsageSnapshot {
    UsageSnapshot(fiveHour: UsageWindow(utilization: pct),
                  sevenDay: UsageWindow(utilization: pct),
                  fetchedAt: Date(timeIntervalSince1970: 0))
}

private func account(_ id: String, slot: Int? = nil) -> Account {
    Account(id: id, alias: id, email: "\(id)@example.com", slot: slot,
            isActive: false, oauthURL: URL(fileURLWithPath: "/dev/null"))
}

@MainActor
private func makeStore(_ results: [String: Result<UsageSnapshot, UsageError>]) -> (UsageStore, URL) {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("usage-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("usage-cache.json")
    return (UsageStore(fetcher: MockFetcher(results: results), cacheFile: cache), cache)
}

@MainActor @Suite struct UsageStoreTests {
    @Test func successMakesFreshFailureIsolated() async {
        let (store, cache) = makeStore(["tok-a": .success(snap(42)), "tok-b": .failure(.network)])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), "tok-a"), (account("b"), "tok-b")])

        #expect(store.states["a"]?.freshness == .fresh)
        #expect(store.states["a"]?.snapshot?.fiveHour?.utilization == 42)
        #expect(store.states["b"]?.freshness == .stale)
        #expect(store.states["b"]?.snapshot == nil)
        #expect(store.states["b"]?.failureCount == 1)
    }

    @Test func failureKeepsPreviousSnapshot() async {
        let (store, cache) = makeStore(["tok": .success(snap(10))])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), "tok")])
        await store.refresh(accounts: [(account("a"), "bad-tok")])  // unknown token -> .network

        #expect(store.states["a"]?.snapshot?.fiveHour?.utilization == 10)  // old data kept
        #expect(store.states["a"]?.freshness == .stale)
        #expect(store.states["a"]?.failureCount == 1)
    }

    @Test func unauthorizedSetsNeedsRelogin() async {
        let (store, cache) = makeStore(["tok": .failure(.unauthorized)])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), "tok")])
        #expect(store.states["a"]?.needsRelogin == true)
        #expect(store.states["a"]?.freshness == .stale)
    }

    @Test func successAfterUnauthorizedClearsRelogin() async {
        let (store, cache) = makeStore(["expired": .failure(.unauthorized),
                                        "fresh": .success(snap(20))])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), "expired")])
        #expect(store.states["a"]?.needsRelogin == true)

        await store.refresh(accounts: [(account("a"), "fresh")])
        #expect(store.states["a"]?.needsRelogin == false)
        #expect(store.states["a"]?.failureCount == 0)
        #expect(store.states["a"]?.freshness == .fresh)
    }

    @Test func missingTokenNeedsRelogin() async {
        let (store, cache) = makeStore([:])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), nil)])
        #expect(store.states["a"]?.needsRelogin == true)
        #expect(store.states["a"]?.snapshot == nil)
    }

    @Test func slotAccountWithoutTokenDoesNotFlagRelogin() async {
        // A slot-having account with no token and no prior state means "no
        // data yet", never "logged out" — see the `account.slot != nil`
        // branch in `refresh`.
        let (store, cache) = makeStore([:])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a", slot: 1), nil)])
        #expect(store.states["a"]?.needsRelogin == false)
        #expect(store.states["a"]?.snapshot == nil)
    }

    @Test func cacheRoundTripLoadsAsStale() async {
        let (store, cache) = makeStore(["tok": .success(snap(55))])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), "tok")])

        let warm = UsageStore(fetcher: MockFetcher(results: [:]), cacheFile: cache)
        warm.loadCache()
        #expect(warm.states["a"]?.snapshot?.fiveHour?.utilization == 55)
        #expect(warm.states["a"]?.freshness == .stale)
    }

    @Test func backoffSchedule() {
        // failureCount 0: never skip
        #expect(!UsageStore.shouldSkip(cycle: 0, failureCount: 0))
        #expect(!UsageStore.shouldSkip(cycle: 3, failureCount: 0))
        // failureCount 1: every 2nd cycle runs
        #expect(!UsageStore.shouldSkip(cycle: 2, failureCount: 1))
        #expect(UsageStore.shouldSkip(cycle: 3, failureCount: 1))
        // failureCount 2: every 4th
        #expect(!UsageStore.shouldSkip(cycle: 4, failureCount: 2))
        #expect(UsageStore.shouldSkip(cycle: 6, failureCount: 2))
        // failureCount >= 3 caps at every 8th
        #expect(!UsageStore.shouldSkip(cycle: 8, failureCount: 5))
        #expect(UsageStore.shouldSkip(cycle: 12, failureCount: 5))
    }

    @Test func backoffSurvivesHugeFailureCounts() {
        // `1 << 63` overflows to Int.min and `1 << 64` to 0 (`cycle % 0` traps);
        // huge counts must behave exactly like the capped every-8th schedule.
        for failures in [63, 64, 100, Int.max] {
            #expect(!UsageStore.shouldSkip(cycle: 0, failureCount: failures))
            #expect(!UsageStore.shouldSkip(cycle: 8, failureCount: failures))
            #expect(!UsageStore.shouldSkip(cycle: 16, failureCount: failures))
            #expect(UsageStore.shouldSkip(cycle: 7, failureCount: failures))
            #expect(UsageStore.shouldSkip(cycle: 9, failureCount: failures))
        }
    }

    @Test func needsReloginSurvivesACacheMissRefreshCycle() async {
        let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
        store.seedNeedsRelogin(["native-0"])

        let account = Account(id: "native-0", alias: nil, email: nil, slot: 0,
                              isActive: true, oauthURL: URL(fileURLWithPath: "/dev/null"))
        await store.refresh(accounts: [(account: account, token: nil)])

        #expect(store.states["native-0"]?.needsRelogin == true)
    }

    @Test func freshAccountWithNoPriorStateDefaultsToNoRelogin() async {
        let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
        let account = Account(id: "native-1", alias: nil, email: nil, slot: 1,
                              isActive: false, oauthURL: URL(fileURLWithPath: "/dev/null"))
        await store.refresh(accounts: [(account: account, token: nil)])

        #expect(store.states["native-1"]?.needsRelogin == false)
    }

    @Test func seedNeedsReloginDoesNotOverwriteExistingState() {
        let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
        store.seedNeedsRelogin(["native-0"])
        #expect(store.states["native-0"]?.needsRelogin == true)

        // A second seed call must not stomp state that's since moved on
        // (e.g. a successful fetch already cleared needsRelogin).
        store.seedNeedsRelogin(["native-0"])
        #expect(store.states["native-0"]?.needsRelogin == true)
    }

    // MARK: - shouldRefresh (popover-open / wake throttle)

    @Test func shouldRefreshAllowedWhenNeverRefreshed() {
        let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
        #expect(store.shouldRefresh(now: Date(), minGap: 30))
    }

    @Test func shouldRefreshAllowedAtOrAfterMinGap() async {
        let (store, cache) = makeStore(["tok": .success(snap(10))])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let t0 = Date(timeIntervalSince1970: 1_000)
        await store.refresh(accounts: [(account("a"), "tok")], now: t0)

        #expect(store.shouldRefresh(now: t0.addingTimeInterval(30), minGap: 30))
        #expect(store.shouldRefresh(now: t0.addingTimeInterval(45), minGap: 30))
    }

    @Test func shouldRefreshSkippedBeforeMinGap() async {
        let (store, cache) = makeStore(["tok": .success(snap(10))])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let t0 = Date(timeIntervalSince1970: 1_000)
        await store.refresh(accounts: [(account("a"), "tok")], now: t0)

        #expect(!store.shouldRefresh(now: t0.addingTimeInterval(29), minGap: 30))
    }

    @Test func failedRefreshDoesNotCountAsRecentSuccessForThrottle() async {
        let (store, cache) = makeStore(["tok": .failure(.network)])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let t0 = Date(timeIntervalSince1970: 1_000)
        await store.refresh(accounts: [(account("a"), "tok")], now: t0)

        // A failed refresh must not start the throttle window — refreshing
        // again a second later is still allowed.
        #expect(store.shouldRefresh(now: t0.addingTimeInterval(1), minGap: 30))
    }

    // MARK: - apply(externalStates:) (token-slayer injection path)

    @Test func applyInjectsExternalStatesById() {
        let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
        let state = AccountUsageState(snapshot: snap(33), freshness: .fresh, needsRelogin: false)
        store.apply(externalStates: ["a": state])
        #expect(store.states["a"]?.snapshot?.fiveHour?.utilization == 33)
        #expect(store.states["a"]?.freshness == .fresh)
    }

    @Test func applyOverwritesExistingStateForSameId() async {
        let (store, cache) = makeStore(["tok": .success(snap(10))])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), "tok")])
        #expect(store.states["a"]?.snapshot?.fiveHour?.utilization == 10)

        store.apply(externalStates: ["a": AccountUsageState(snapshot: snap(77), freshness: .fresh)])
        #expect(store.states["a"]?.snapshot?.fiveHour?.utilization == 77)
    }

    @Test func applySetsLastSuccessfulRefreshAtWhenNonEmpty() {
        let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
        let now = Date(timeIntervalSince1970: 5_000)
        store.apply(externalStates: ["a": AccountUsageState(snapshot: snap(1), freshness: .fresh)], now: now)
        #expect(!store.shouldRefresh(now: now.addingTimeInterval(1), minGap: 30))
    }

    @Test func applyWithEmptyStatesDoesNotDisturbThrottle() {
        let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
        store.apply(externalStates: [:], now: Date(timeIntervalSince1970: 5_000))
        #expect(store.shouldRefresh(now: Date(timeIntervalSince1970: 5_001), minGap: 30))
    }

    @Test func markStaleDowngradesExistingFreshState() {
        let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
        store.apply(externalStates: ["a": AccountUsageState(snapshot: snap(1), freshness: .fresh)])
        store.markStale(["a"])
        #expect(store.states["a"]?.freshness == .stale)
        #expect(store.states["a"]?.snapshot?.fiveHour?.utilization == 1)  // snapshot kept
    }

    @Test func markStaleIgnoresIdsWithNoExistingState() {
        let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
        store.markStale(["never-seen"])
        #expect(store.states["never-seen"] == nil)
    }

    @Test func appliedStateSurvivesCacheRoundTrip() {
        let cache = tempCacheFile()
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = UsageStore(fetcher: FailingFetcher(), cacheFile: cache)
        store.apply(externalStates: ["a": AccountUsageState(snapshot: snap(66), freshness: .fresh)])

        let warm = UsageStore(fetcher: FailingFetcher(), cacheFile: cache)
        warm.loadCache()
        #expect(warm.states["a"]?.snapshot?.fiveHour?.utilization == 66)
    }
}
