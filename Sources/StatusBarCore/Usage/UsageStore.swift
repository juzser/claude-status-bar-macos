import Foundation

public enum Freshness: Equatable, Sendable {
    case fresh, stale, none
}

public struct AccountUsageState: Equatable, Sendable {
    public var snapshot: UsageSnapshot?
    public var freshness: Freshness
    public var needsRelogin: Bool
    public var failureCount: Int

    public init(snapshot: UsageSnapshot? = nil, freshness: Freshness = .none,
                needsRelogin: Bool = false, failureCount: Int = 0) {
        self.snapshot = snapshot
        self.freshness = freshness
        self.needsRelogin = needsRelogin
        self.failureCount = failureCount
    }
}

@MainActor
public final class UsageStore {
    let fetcher: UsageFetching
    let cacheFile: URL
    public private(set) var states: [String: AccountUsageState] = [:]

    public init(fetcher: UsageFetching, cacheFile: URL) {
        self.fetcher = fetcher
        self.cacheFile = cacheFile
    }

    /// Exponential per-account backoff after failures, capped at every 8th cycle.
    /// `failureCount` is branched (not `min(1 << failureCount, 8)`) because a
    /// sustained-failure account can accumulate a huge failureCount over days;
    /// `1 << 63` overflows to `Int.min` and `1 << 64` to 0, and `cycle % 0` traps.
    public static func shouldSkip(cycle: Int, failureCount: Int) -> Bool {
        guard failureCount > 0 else { return false }
        let interval = failureCount >= 3 ? 8 : 1 << failureCount
        return cycle % interval != 0
    }

    /// A cux cache snapshot older than this shows as stale — cux's hooks
    /// normally repoll within minutes, so a 30-minute-old entry means cux
    /// hasn't been active.
    public static let cuxCacheFreshFor: TimeInterval = 30 * 60

    public func refresh(accounts: [(account: Account, token: String?)]) async {
        await refresh(accounts: accounts.map { ($0.account, $0.token, nil) })
    }

    public func refresh(accounts: [(account: Account, token: String?, cached: UsageSnapshot?)],
                        now: Date = Date()) async {
        let fetcher = self.fetcher
        let fetched = await withTaskGroup(
            of: (String, Result<UsageSnapshot, UsageError>).self
        ) { group in
            for (account, token, _) in accounts {
                guard let token else { continue }
                group.addTask {
                    do {
                        return (account.id, .success(try await fetcher.fetch(token: token)))
                    } catch let error as UsageError {
                        return (account.id, .failure(error))
                    } catch {
                        return (account.id, .failure(.network))
                    }
                }
            }
            var collected: [String: Result<UsageSnapshot, UsageError>] = [:]
            for await (id, result) in group {
                collected[id] = result
            }
            return collected
        }

        for (account, token, cached) in accounts {
            let id = account.id
            var state = states[id] ?? AccountUsageState()
            switch token.flatMap({ _ in fetched[id] }) {
            case .success(let snapshot):
                state = AccountUsageState(snapshot: snapshot, freshness: .fresh)
            case .failure(.unauthorized):
                state.freshness = .stale
                state.needsRelogin = true
                state.failureCount += 1
            case .failure:
                state.freshness = .stale
                state.failureCount += 1
            case nil:  // no token — cux slot account or missing credentials
                if let cached {
                    let fresh = now.timeIntervalSince(cached.fetchedAt) <= Self.cuxCacheFreshFor
                    state = AccountUsageState(snapshot: cached,
                                              freshness: fresh ? .fresh : .stale)
                } else if account.slot != nil {
                    // A slot-having account with no cache hit and no prior
                    // state defaults to needsRelogin == false (via
                    // AccountUsageState()'s own default) — but if this ID
                    // was pre-seeded via seedNeedsRelogin (a migrated
                    // native account with no vault backup), that flag
                    // must survive this cycle, not be reset here.
                } else {
                    state.needsRelogin = true
                }
            }
            states[id] = state
        }
        saveCache()
    }

    /// Marks the given account ids as needing relogin, without disturbing
    /// any id that already has state (e.g. from a completed fetch). Used by
    /// `AppState.resolveAccounts()` right after loading a migrated native
    /// account whose credential vault backup couldn't be read.
    public func seedNeedsRelogin(_ ids: [String]) {
        for id in ids where states[id] == nil {
            states[id] = AccountUsageState(needsRelogin: true)
        }
    }

    public func loadCache() {
        guard let data = try? Data(contentsOf: cacheFile),
              let cached = try? decoder().decode([String: UsageSnapshot].self, from: data)
        else { return }
        for (id, snapshot) in cached where states[id] == nil {
            states[id] = AccountUsageState(snapshot: snapshot, freshness: .stale)
        }
    }

    private func saveCache() {
        let snapshots = states.compactMapValues(\.snapshot)
        guard let data = try? encoder().encode(snapshots) else { return }
        try? AtomicFile.write(data, to: cacheFile)
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
