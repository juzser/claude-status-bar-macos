import Foundation
import Observation
import StatusBarCore

/// Single source of truth for the UI. Task 13 replaces the constants below
/// with SettingsStore-backed values.
@Observable @MainActor
final class AppState {
    // Settings constants until Task 13 wires SettingsStore.
    let pollMinutes = 5
    let yellowAt: Double = 50
    let redAt: Double = 80
    let displayStyle: DisplayStyle = .full
    let showUsageOnBar = true

    private(set) var sessions: [SessionRecord] = []
    private(set) var display: SessionRecord?
    private(set) var accounts: [Account] = []
    private(set) var currentVerb: String
    let usageStore: UsageStore
    let paths: AppPaths

    private var verbCycler = VerbCycler()
    private var watcher: DirectoryWatcher?
    private var pollTask: Task<Void, Never>?
    private var reaggregateTask: Task<Void, Never>?
    private var pollCycle = 0

    private let cuxRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cux", isDirectory: true)
    private let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        self.usageStore = UsageStore(fetcher: UsageClient(), cacheFile: paths.usageCacheFile)
        self.currentVerb = ThinkingVerbs.all[0]
        self.currentVerb = verbCycler.next()
    }

    func start() {
        try? paths.ensureDirs()
        usageStore.loadCache()
        accounts = AccountDiscovery.discover(cuxRoot: cuxRoot, credentialsFile: credentialsFile)
        reaggregate()

        watcher = DirectoryWatcher(url: paths.sessionsDir) { [weak self] in
            self?.reaggregate()
        }
        // Safety net: stale sessions must disappear even with no file events.
        reaggregateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.reaggregate()
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let minutes = self?.pollMinutes ?? 5
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    func reaggregate() {
        sessions = SessionAggregator.loadSessions(from: paths.sessionsDir, now: Date())
        let previous = display?.state
        display = SessionAggregator.displayState(sessions)
        if display?.state == .thinking, previous != .thinking {
            currentVerb = verbCycler.next()
        }
    }

    func refreshUsageNow() async {
        accounts = AccountDiscovery.discover(cuxRoot: cuxRoot, credentialsFile: credentialsFile)
        await usageStore.refresh(accounts: accounts.map { ($0, token(for: $0)) })
    }

    var labelModel: MenuBarLabelModel {
        let activeUsage = accounts.first(where: \.isActive).flatMap { usageStore.states[$0.id] }
            ?? accounts.first.flatMap { usageStore.states[$0.id] }
        return MenuBarText.model(display: display, usage: activeUsage,
                                 style: displayStyle, showUsage: showUsageOnBar,
                                 yellowAt: yellowAt, redAt: redAt,
                                 verb: currentVerb, now: Date())
    }

    private func pollOnce() async {
        accounts = AccountDiscovery.discover(cuxRoot: cuxRoot, credentialsFile: credentialsFile)
        let cycle = pollCycle
        pollCycle += 1
        let due = accounts.filter { account in
            let failures = usageStore.states[account.id]?.failureCount ?? 0
            return !UsageStore.shouldSkip(cycle: cycle, failureCount: failures)
        }
        guard !due.isEmpty else { return }
        await usageStore.refresh(accounts: due.map { ($0, token(for: $0)) })
    }

    /// Token is read at fetch time only, kept in a local, never stored or logged.
    private func token(for account: Account) -> String? {
        guard let data = try? Data(contentsOf: account.oauthURL) else { return nil }
        return AccountDiscovery.accessToken(from: data)
    }
}
