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

private func snap(_ pct: Double) -> UsageSnapshot {
    UsageSnapshot(fiveHour: UsageWindow(utilization: pct),
                  sevenDay: UsageWindow(utilization: pct),
                  fetchedAt: Date(timeIntervalSince1970: 0))
}

private func account(_ id: String) -> Account {
    Account(id: id, alias: id, email: "\(id)@example.com", slot: nil,
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

    @Test func missingTokenNeedsRelogin() async {
        let (store, cache) = makeStore([:])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), nil)])
        #expect(store.states["a"]?.needsRelogin == true)
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
}
