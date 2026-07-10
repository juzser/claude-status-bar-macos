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
    public static func shouldSkip(cycle: Int, failureCount: Int) -> Bool {
        guard failureCount > 0 else { return false }
        let interval = min(1 << failureCount, 8)
        return cycle % interval != 0
    }

    public func refresh(accounts: [(account: Account, token: String?)]) async {
        let fetcher = self.fetcher
        let results = await withTaskGroup(
            of: (String, Result<UsageSnapshot, UsageError>?).self
        ) { group in
            for (account, token) in accounts {
                group.addTask {
                    guard let token else { return (account.id, nil) }
                    do {
                        return (account.id, .success(try await fetcher.fetch(token: token)))
                    } catch let error as UsageError {
                        return (account.id, .failure(error))
                    } catch {
                        return (account.id, .failure(.network))
                    }
                }
            }
            var collected: [(String, Result<UsageSnapshot, UsageError>?)] = []
            for await item in group { collected.append(item) }
            return collected
        }

        for (id, result) in results {
            var state = states[id] ?? AccountUsageState()
            switch result {
            case .success(let snapshot):
                state = AccountUsageState(snapshot: snapshot, freshness: .fresh)
            case .failure(.unauthorized):
                state.freshness = .stale
                state.needsRelogin = true
                state.failureCount += 1
            case .failure:
                state.freshness = .stale
                state.failureCount += 1
            case nil:  // no token available
                state.needsRelogin = true
            }
            states[id] = state
        }
        saveCache()
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
