import Foundation
import Observation
import StatusBarCore

/// Single source of truth for the UI.
@Observable @MainActor
final class AppState {
    let settings: SettingsStore
    var pollMinutes: Int { settings.pollMinutes }
    var yellowAt: Double { settings.yellowAt }
    var redAt: Double { settings.redAt }
    var displayStyle: DisplayStyle { settings.displayStyle }
    var showUsageOnBar: Bool { settings.showUsageOnBar }
    var visibleAccounts: [Account] {
        accounts.filter { !settings.hiddenAccounts.contains($0.id) }
    }

    private(set) var sessions: [SessionRecord] = []
    /// sessionId -> Claude Code session title (last ai-title in the transcript).
    private(set) var sessionTitles: [String: String] = [:]
    private var titleCheckedAt: [String: Date] = [:]
    private(set) var display: SessionRecord?
    private(set) var accounts: [Account] = []
    private(set) var currentVerb: String
    /// 1 Hz heartbeat for the menu bar elapsed counter; advances only while busy.
    private(set) var tick = Date()
    let usageStore: UsageStore
    let paths: AppPaths

    private let cuxRefresher = CuxRefresher()
    private let cuxAccountSwitcher = CuxAccountSwitcher()
    private var verbCycler = VerbCycler()
    private var watcher: DirectoryWatcher?
    private var pollTask: Task<Void, Never>?
    private var reaggregateTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var tickInterval: Duration = .seconds(1)
    private var pollCycle = 0
    private var started = false

    private let cuxRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cux", isDirectory: true)
    private let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    // `settings` defaults via `?? SettingsStore()` in the body, not as a parameter
    // default: a MainActor-isolated default-argument expression doesn't compile
    // under Swift language mode v5 (SE-0411 isolated default values needs mode 6).
    init(paths: AppPaths = AppPaths(), settings: SettingsStore? = nil) {
        self.paths = paths
        self.settings = settings ?? SettingsStore()
        self.usageStore = UsageStore(fetcher: UsageClient(), cacheFile: paths.usageCacheFile)
        self.currentVerb = ThinkingVerbs.all[0]
        self.currentVerb = verbCycler.next(from: self.settings.messageStyle.thinking)
    }

    func start() {
        // Re-entrancy guard: a second .onAppear would otherwise double the
        // watcher and the poll/reaggregate loops.
        guard !started else { return }
        started = true
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
            currentVerb = verbCycler.next(from: settings.messageStyle.thinking)
        }
        refreshSessionTitles()
        updateTicker()
    }

    /// Transcript tail-reads happen here, throttled to once per session per
    /// minute — never in the popover's 1 Hz render path.
    private func refreshSessionTitles() {
        let now = Date()
        let live = Set(sessions.map(\.sessionId))
        sessionTitles = sessionTitles.filter { live.contains($0.key) }
        titleCheckedAt = titleCheckedAt.filter { live.contains($0.key) }
        for session in sessions {
            guard let path = session.transcriptPath else { continue }
            if let checked = titleCheckedAt[session.sessionId],
               now.timeIntervalSince(checked) < 60 { continue }
            titleCheckedAt[session.sessionId] = now
            if let title = SessionTitle.read(transcript: URL(fileURLWithPath: path)) {
                sessionTitles[session.sessionId] = title
            }
        }
    }

    /// Drives the elapsed counter and shimmer while a session is busy — 30 fps
    /// when activity text is on the bar (the shimmer needs sub-second frames),
    /// 1 Hz for icon-only/compact styles. A plain task loop, not TimelineView:
    /// a periodic TimelineView in the MenuBarExtra label re-anchors its
    /// schedule at `.now` on every label re-render, so the first entry is
    /// always already due — the main thread spins at 100% CPU and the status
    /// item never finishes appearing (observed on macOS 26).
    private func updateTicker() {
        if display?.busySince != nil {
            let interval: Duration = displayStyle == .iconOnly || displayStyle == .compact
                ? .seconds(1) : .milliseconds(33)
            guard tickTask == nil || interval != tickInterval else { return }
            tickTask?.cancel()
            tickInterval = interval
            tick = Date()
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    self?.tick = Date()
                }
            }
        } else {
            tickTask?.cancel()
            tickTask = nil
        }
    }

    /// Called when the user picks a new message style: forget the no-repeat
    /// memory (it indexes the old pool) and re-pick so a bar currently in
    /// .thinking re-renders with the new style at once.
    func rerollThinkingPhrase() {
        verbCycler.reset()
        currentVerb = verbCycler.next(from: settings.messageStyle.thinking)
    }

    func refreshUsageNow() async {
        accounts = AccountDiscovery.discover(cuxRoot: cuxRoot, credentialsFile: credentialsFile)
        // Slot accounts are tokenless, so their usage comes from cux's own
        // cache — ask cux to repoll it first or the mirror stays session-stale.
        await cuxRefresher.refreshIfNeeded(accounts: accounts)
        await usageStore.refresh(accounts: usageInputs(accounts))
    }

    /// Switches the active cux slot, then re-discovers accounts and refreshes
    /// usage so `isActive` and the usage bars reflect the new slot right away.
    /// No-op for the plain credentials-file account (`slot == nil`), which
    /// has nothing to switch to.
    func switchAccount(_ account: Account) async {
        guard let slot = account.slot else { return }
        _ = await cuxAccountSwitcher.switchTo(slot: slot)
        await refreshUsageNow()
    }

    /// Re-fetches only accounts flagged needs-relogin. Runs when the popover
    /// opens: after the user logs back in, the poll loop's failure backoff
    /// (every 8th cycle at 3+ failures) would otherwise keep the stale badge
    /// up for the better part of an hour.
    func recheckReloginAccounts() async {
        let flagged = accounts.filter { usageStore.states[$0.id]?.needsRelogin == true }
        guard !flagged.isEmpty else { return }
        await usageStore.refresh(accounts: usageInputs(flagged))
    }

    var labelModel: MenuBarLabelModel {
        let activeUsage = accounts.first(where: \.isActive).flatMap { usageStore.states[$0.id] }
            ?? accounts.first.flatMap { usageStore.states[$0.id] }
        return MenuBarText.model(display: display, usage: activeUsage,
                                 style: displayStyle, showUsage: showUsageOnBar,
                                 showElapsed: settings.showElapsedOnBar,
                                 yellowAt: yellowAt, redAt: redAt,
                                 verb: currentVerb, messageStyle: settings.messageStyle,
                                 now: tick)
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
        await cuxRefresher.refreshIfNeeded(accounts: due)
        await usageStore.refresh(accounts: usageInputs(due))
    }

    /// Pairs each account with its token and, for tokenless cux slots, the
    /// snapshot cux itself polled into ~/.cux/runtime/usage-cache.json
    /// (joined on organizationUuid). Reads the cache file once per refresh.
    private func usageInputs(
        _ accounts: [Account]
    ) -> [(account: Account, token: String?, cached: UsageSnapshot?)] {
        let cache = CuxUsageCache.load(
            file: cuxRoot.appendingPathComponent("runtime/usage-cache.json"))
        return accounts.map { account in
            (account, token(for: account),
             account.organizationUuid.flatMap { cache[$0] })
        }
    }

    /// Token is read at fetch time only, kept in a local, never stored or
    /// logged. cux v0.2.11+ keeps the real token only in the Keychain, never
    /// in a slot's oauth.json — but cux swaps just the *active* slot's token
    /// into the Keychain, so the fallback is gated on `isActive` to avoid
    /// misattributing that token to other, inactive accounts.
    private func token(for account: Account) -> String? {
        if let data = try? Data(contentsOf: account.oauthURL),
           let token = AccountDiscovery.accessToken(from: data) {
            return token
        }
        guard account.isActive else { return nil }
        return AccountDiscovery.keychainAccessToken()
    }
}
