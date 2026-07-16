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

    // cux slot accounts carry no token in oauth.json (real tokens live in the
    // Keychain); usage comes from cux's own cache, keyed by organizationUuid.

    @Test func cuxCacheSnapshotFeedsUsageWithoutToken() async {
        let (store, cache) = makeStore([:])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let now = Date()
        let cached = UsageSnapshot(fiveHour: UsageWindow(utilization: 23),
                                   sevenDay: UsageWindow(utilization: 65),
                                   fetchedAt: now.addingTimeInterval(-60))
        await store.refresh(accounts: [(account("a", slot: 1), nil, cached)], now: now)
        #expect(store.states["a"]?.snapshot?.fiveHour?.utilization == 23)
        #expect(store.states["a"]?.freshness == .fresh)
        #expect(store.states["a"]?.needsRelogin == false)
    }

    @Test func oldCuxCacheSnapshotIsStale() async {
        let (store, cache) = makeStore([:])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let now = Date()
        let cached = UsageSnapshot(fiveHour: UsageWindow(utilization: 23), sevenDay: nil,
                                   fetchedAt: now.addingTimeInterval(-UsageStore.cuxCacheFreshFor - 1))
        await store.refresh(accounts: [(account("a", slot: 1), nil, cached)], now: now)
        #expect(store.states["a"]?.snapshot?.fiveHour?.utilization == 23)
        #expect(store.states["a"]?.freshness == .stale)
        #expect(store.states["a"]?.needsRelogin == false)
    }

    @Test func cuxAccountWithoutCacheEntryDoesNotFlagRelogin() async {
        // cux owns auth for slot accounts — a missing cache entry means
        // "no data yet", never "logged out".
        let (store, cache) = makeStore([:])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a", slot: 1), nil, nil)])
        #expect(store.states["a"]?.needsRelogin == false)
        #expect(store.states["a"]?.snapshot == nil)
    }

    @Test func cachedSnapshotClearsPriorReloginFlag() async {
        let (store, cache) = makeStore([:])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        // Legacy state from before the cux-cache path shipped.
        await store.refresh(accounts: [(account("a"), nil)])
        #expect(store.states["a"]?.needsRelogin == true)

        let now = Date()
        let cached = UsageSnapshot(fiveHour: UsageWindow(utilization: 10), sevenDay: nil,
                                   fetchedAt: now.addingTimeInterval(-60))
        await store.refresh(accounts: [(account("a", slot: 1), nil, cached)], now: now)
        #expect(store.states["a"]?.needsRelogin == false)
        #expect(store.states["a"]?.failureCount == 0)
        #expect(store.states["a"]?.freshness == .fresh)
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
        await store.refresh(accounts: [(account: account, token: nil, cached: nil)])

        #expect(store.states["native-0"]?.needsRelogin == true)
    }

    @Test func freshAccountWithNoPriorStateDefaultsToNoRelogin() async {
        let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
        let account = Account(id: "native-1", alias: nil, email: nil, slot: 1,
                              isActive: false, oauthURL: URL(fileURLWithPath: "/dev/null"))
        await store.refresh(accounts: [(account: account, token: nil, cached: nil)])

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
}
