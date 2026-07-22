import AppKit
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
    /// Set when `switchAccount` fails, cleared on the next attempt that
    /// succeeds — surfaced as an inline warning next to the account's row.
    private(set) var switchFailedAccountId: String?
    /// Stderr text from the most recent failed slayer-mode switch, paired
    /// with `switchFailedAccountId`. Nil for a native-mode failure — the UI
    /// falls back to its existing generic message in that case.
    private(set) var switchFailedMessage: String?
    /// 1 Hz heartbeat for the menu bar elapsed counter; advances only while busy.
    private(set) var tick = Date()
    private(set) var updateAvailable: ReleaseInfo?
    let usageStore: UsageStore
    let paths: AppPaths

    /// Cached resolved path once `useTokenSlayer` is on and the binary
    /// exists — nil means native mode is active (setting off, or the CLI
    /// isn't installed). Drives the UI's subtle backend indicator.
    private(set) var slayerBinaryPath: String?
    var usingSlayerBackend: Bool { slayerBinaryPath != nil }
    /// Whether the token-slayer CLI is installed on this machine, resolved
    /// once at launch independently of `settings.useTokenSlayer`. Drives
    /// whether the Settings toggle is offered at all — a toggle for a backend
    /// that isn't installed is just a dead control. Like every other
    /// token-slayer path, resolution is cached for the process lifetime
    /// (TokenSlayerCLI.resolveBinary), so installing the CLI mid-session
    /// needs a relaunch to be picked up — the same tradeoff the rest of the
    /// slayer integration already makes.
    private(set) var tokenSlayerInstalled = false
    /// Message from the most recent failed slayer `list`/`status` read —
    /// surfaced as a small footer in Settings; nil once a call succeeds. A
    /// `sessions` failure does *not* set this: it only backs the secondary
    /// billed-account annotation on session rows (see
    /// `refreshSessionAnnotations(binaryPath:)`), so it fails silently and
    /// leaves any prior annotations in place rather than raising a footer
    /// error for a feature that's cosmetic to begin with.
    private(set) var slayerErrorMessage: String?
    /// account id -> slayer `name`, the only stable switch target (`index`
    /// is documented as unstable) — populated on every successful
    /// `refreshFromSlayer`.
    private var slayerAccountNames: [String: String] = [:]
    /// sessionId -> token-slayer `billed_account`, joined onto hook-based
    /// session rows as a secondary annotation. Empty outside slayer mode.
    private(set) var sessionBilledAccounts: [String: String] = [:]

    private let tokenSlayerCLI = TokenSlayerCLI.shared
    private let nativeAccountSwitcher = NativeAccountSwitcher()
    private let accountCapture: AccountCapture
    private let updateChecker = UpdateChecker()
    private var verbCycler = VerbCycler()
    private var watcher: DirectoryWatcher?
    private var pollTask: Task<Void, Never>?
    private var reaggregateTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var tickInterval: Duration = .seconds(1)
    private var pollCycle = 0
    private var started = false
    /// Guards `refreshUsageIfNeeded()` against the popover-open and
    /// wake-from-sleep triggers firing near-simultaneously: both check
    /// `usageStore.shouldRefresh()` before either's `refreshUsageNow()` call
    /// has completed, so `lastSuccessfulRefreshAt` alone can't stop a second
    /// concurrent refresh. Race-free because the check-and-set in
    /// `refreshUsageIfNeeded()` has no `await` between them — the whole
    /// guard runs as one uninterrupted step on this actor.
    private var refreshInFlight = false
    /// Stored (not fire-and-forget) so `usageInputs(_:)` can await it before
    /// the first real Keychain read of a launch — see its assignment in
    /// `start()` for why that ordering matters.
    private var selfHealTask: Task<Void, Never>?
    /// Kept only so the observer could be removed later; nothing currently
    /// does, matching the other loop `Task`s in `start()` which also run for
    /// the app's lifetime with no explicit teardown.
    private var wakeObserver: NSObjectProtocol?
    /// Screen unlock is the other sharp, cheap signal (alongside wake) that
    /// the live item's ACL may have been reset without this app's knowledge
    /// (Finding #4) — e.g. a reboot or fast-user-switch doesn't fire
    /// `didWakeNotification` but does unlock the screen right before the
    /// user is likely to invoke `claude`.
    private var screenUnlockObserver: NSObjectProtocol?
    /// Whether this launch's one *interactive* `LiveCredentialSelfHeal`
    /// attempt has already been spent — see `attemptLiveCredentialSelfHeal()`.
    /// `run()`'s own `isTrusted` probe is non-interactive and can keep
    /// failing indefinitely, so without this gate every call site (launch,
    /// wake, unlock, every `usageInputs(_:)` cycle) would retry the
    /// *interactive* repair read forever — a prompt storm, not a fix.
    ///
    /// `ClaudeStatusBar` is an untested executable target (only
    /// `StatusBarCore` runs under `swift test`), so this gate and the call
    /// sites sharing it are covered indirectly, via `LiveCredentialSelfHeal`'s
    /// `allowInteractive` tests plus `swift build` and manual exercise.
    private var liveCredentialSelfHealAttempted = false

    private let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    // `settings` defaults via `?? SettingsStore()` in the body, not as a parameter
    // default: a MainActor-isolated default-argument expression doesn't compile
    // under Swift language mode v5 (SE-0411 isolated default values needs mode 6).
    init(paths: AppPaths = AppPaths(), settings: SettingsStore? = nil) {
        self.paths = paths
        self.settings = settings ?? SettingsStore()
        self.accountCapture = AccountCapture(storeFile: paths.root.appendingPathComponent("native-accounts.json"))
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
        // Resolved once here, unconditionally — regardless of whether
        // `settings.useTokenSlayer` is on — so the Settings toggle knows
        // whether to offer itself at all even while the setting is off (see
        // `tokenSlayerInstalled`'s doc comment). Backgrounded like
        // `selfHealTask` below since `resolveBinary()` may shell out and
        // start() itself must stay synchronous; `TokenSlayerCLI.resolveBinary`
        // caches for the actor's lifetime, so this is reused rather than
        // duplicated by the later `resolveSlayerBinaryIfEnabled()` calls.
        Task { [weak self] in
            guard let self else { return }
            self.tokenSlayerInstalled = await self.tokenSlayerCLI.resolveBinary() != nil
        }
        // Native discovery is skipped up front when the setting says slayer
        // mode will own this session — avoids both an unnecessary native
        // Keychain-adjacent read and the cosmetic flash of native accounts
        // in the popover before the first refreshFromSlayer lands. Only the
        // synchronous half of "is slayer active" is checked here (the
        // setting) since start() itself must stay synchronous and full
        // resolution needs an await; if the setting's on but the binary
        // then fails to resolve, refreshUsage(live:)'s native branch
        // re-seeds `accounts` itself moments later (the very next Task,
        // scheduled by .onAppear right after start() returns) — nothing is
        // lost by not seeding it here too.
        if !settings.useTokenSlayer {
            accounts = resolveAccounts()
        }
        // Re-assert the live credentials' Keychain ACL once per launch so an
        // account that has never completed a successful switch (the only
        // path that used to fix this) still stops re-prompting for access.
        // Backgrounded: resolving claude's binary may shell out (see
        // ClaudeBinaryLocator), and start() itself must stay synchronous.
        //
        // Stored rather than fire-and-forget: AccountDiscovery's Keychain
        // read for the active account (unlike this self-heal probe) doesn't
        // set kSecUseAuthenticationUIFail, so it can trigger a blocking
        // native Keychain confirmation dialog if the ACL isn't trusted yet.
        // An un-awaited Task here raced against the first refresh with no
        // ordering guarantee — usageInputs(_:) awaits selfHealTask so the
        // fast, non-interactive ACL re-assertion always gets first crack at
        // fixing trust before that interactive-capable read can fire.
        //
        // The slayer-mode skip lives inside `attemptLiveCredentialSelfHeal()`
        // rather than here: the full "will slayer own this session" check
        // needs the async binary resolution, which can only happen once we're
        // off the synchronous start() call stack, and every other call site
        // needs the same skip.
        selfHealTask = Task { [weak self] in
            await self?.attemptLiveCredentialSelfHeal()
        }
        // claude's own token refresh can reset the ACL mid-session (see
        // usageInputs(_:)'s doc comment) — after a long sleep, the token is
        // likelier to be due for refresh right as the user resumes work, and
        // self-heal's other triggers (this launch-time run, and the one
        // usageInputs(_:) re-runs on every call) only fire on the next poll
        // cycle or account switch. That leaves a window, right when the user
        // is most likely to invoke claude, where the ACL is untrusted and
        // Keychain prompts. Waking is a sharp, cheap signal to close it early.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.attemptLiveCredentialSelfHeal()
                // Waking is also a sharp signal that usage data may be
                // stale (the poll loop paused for the whole sleep). Throttled
                // like the popover-open trigger — see refreshUsageIfNeeded().
                await self.refreshUsageIfNeeded()
            }
        }
        // Finding #4: screen unlock, observed the same way — reboot and
        // fast-user-switch land here without ever firing
        // `didWakeNotification`, and both are exactly the kind of event
        // that can precede an ACL reset going unnoticed until the next
        // interactive-capable read. `DistributedNotificationCenter` (not
        // `NSWorkspace`) because `com.apple.screenIsUnlocked` is a
        // system-wide distributed notification, not a workspace one.
        screenUnlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                await self.attemptLiveCredentialSelfHeal()
                await self.refreshUsageIfNeeded()
            }
        }
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
        updateCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdates()
                try? await Task.sleep(for: .seconds(Int(UpdateChecker.minInterval)))
            }
        }
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.recheckReloginAccounts()
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

    /// Manual "Check for Updates" button: bypasses the background loop's
    /// rate limit. Only overwrites `updateAvailable` when a newer release is
    /// actually found — a failed or up-to-date check leaves it as-is.
    func checkForUpdatesNow() async {
        if let release = await updateChecker.checkNow(currentVersion: AppVersion.current) {
            updateAvailable = release
        }
    }

    private func checkForUpdates() async {
        if let release = await updateChecker.checkIfNeeded(currentVersion: AppVersion.current) {
            updateAvailable = release
        }
    }

    func refreshUsageNow() async {
        await refreshUsage(live: true)
    }

    /// Backend-branching core of `refreshUsageNow()`/`refreshUsageIfNeeded()`.
    /// `live` only matters in slayer mode (`status --json` vs. cached
    /// `list --json`, per the CLI's own cadence guidance) — native mode has
    /// no such distinction and ignores it, so its behavior is unchanged.
    private func refreshUsage(live: Bool) async {
        if let binaryPath = await resolveSlayerBinaryIfEnabled() {
            await refreshFromSlayer(binaryPath: binaryPath, live: live)
            return
        }
        accounts = resolveAccounts()
        await usageStore.refresh(accounts: await usageInputs(accounts))
    }

    /// Slayer-mode setting check + cached binary resolution in one place —
    /// every entry point that might talk to token-slayer calls this first so
    /// `slayerBinaryPath`/`usingSlayerBackend` (the UI's backend indicator)
    /// always reflects the most recent check.
    private func resolveSlayerBinaryIfEnabled() async -> String? {
        guard settings.useTokenSlayer else {
            slayerBinaryPath = nil
            return nil
        }
        let path = await tokenSlayerCLI.resolveBinary()
        slayerBinaryPath = path
        return path
    }

    /// Fetches accounts/usage from token-slayer and injects them, bypassing
    /// every native path (Keychain reads, `TokenResolution`, direct
    /// api.anthropic.com fetches) entirely — the "zero native I/O in slayer
    /// mode" requirement.
    private func refreshFromSlayer(binaryPath: String, live: Bool) async {
        switch await tokenSlayerCLI.listAccounts(binaryPath: binaryPath, live: live) {
        case .success(let doc):
            slayerErrorMessage = nil
            // Deduped first: two slots can share a `uuid` (e.g. an account
            // re-added under a new name while the old slot still exists),
            // and `Dictionary(uniqueKeysWithValues:)` traps on a duplicate
            // key — see TokenSlayerMapping.dedupedById's doc comment.
            let deduped = TokenSlayerMapping.dedupedById(doc.accounts)
            accounts = deduped.map(TokenSlayerMapping.account(from:))
            slayerAccountNames = Dictionary(
                uniqueKeysWithValues: deduped.map { (TokenSlayerMapping.accountId(for: $0), $0.name) })
            let states = Dictionary(
                uniqueKeysWithValues: deduped.map { (TokenSlayerMapping.accountId(for: $0), TokenSlayerMapping.usageState(from: $0)) })
            usageStore.apply(externalStates: states)
        case .failure(let error):
            slayerErrorMessage = Self.message(for: error)
            // Dim the previously-fetched rows rather than leaving them
            // looking fresh forever — mirrors the native failure branch in
            // UsageStore.refresh(accounts:), which marks a lost connection
            // `.stale` the same way.
            usageStore.markStale(Array(slayerAccountNames.keys))
        }
    }

    private static func message(for error: TokenSlayerError) -> String {
        switch error {
        case .binaryNotFound: return "token-slayer binary not found"
        case .invalidOutput: return "token-slayer returned unexpected output"
        case .commandFailed(let message): return message
        }
    }

    /// Popover-open and wake-from-sleep both call this instead of
    /// `refreshUsageNow()` directly: it skips the refresh when
    /// `UsageStore.shouldRefresh` says the last successful fetch is still
    /// recent, so neither trigger can hammer the API by firing repeatedly
    /// (popover reopened, laptop waking in quick succession). The throttle
    /// window itself is decided in StatusBarCore (testable); a throttled-in
    /// call still goes through the normal `refreshUsageNow()` path, so the
    /// existing per-account failure backoff still applies.
    ///
    /// `refreshInFlight` additionally covers the case the timestamp-based
    /// throttle alone can't: wake and popover-open firing close enough
    /// together that neither's `refreshUsageNow()` has finished (and so
    /// written `lastSuccessfulRefreshAt`) by the time the other's check
    /// runs. Without it both would pass `shouldRefresh()` and fire a
    /// duplicate concurrent fetch.
    func refreshUsageIfNeeded() async {
        guard !refreshInFlight, usageStore.shouldRefresh() else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        // Popover-open/wake want the cached, fast `list --json` in slayer
        // mode — the poll loop is what earns a live `status --json`.
        await refreshUsage(live: false)
    }

    private func resolveAccounts() -> [Account] {
        let nativeFile = paths.root.appendingPathComponent("native-accounts.json")
        let nativeState = NativeAccountStore.load(file: nativeFile)
        guard !nativeState.accounts.isEmpty else {
            return AccountDiscovery.discover(credentialsFile: credentialsFile)
        }
        let flaggedIds = nativeState.accounts.filter(\.needsRelogin).map(\.id)
        usageStore.seedNeedsRelogin(flaggedIds)
        return NativeAccountStore.toAccounts(nativeState)
    }

    /// Switches the active account. In slayer mode this runs `token-slayer
    /// switch <name>` (never `force-switch`) and, on success, re-runs the
    /// cached `list --json` per the contract; on failure the CLI's own
    /// stderr is surfaced verbatim rather than the generic native message.
    /// Native mode is unchanged: NativeAccountSwitcher, then a full usage
    /// refresh so isActive/usage bars reflect the switch immediately. No-op
    /// for the plain default account (slot == nil) — it has nothing to
    /// switch to, and the UI never shows a Switch button for it (see
    /// AccountsSection.swift).
    func switchAccount(_ account: Account) async {
        guard account.slot != nil else { return }
        if let binaryPath = await resolveSlayerBinaryIfEnabled() {
            guard let target = slayerAccountNames[account.id] else {
                // Reachable right after launch (before the first
                // refreshFromSlayer lands) or right after toggling the
                // setting on (accounts still holds a stale native/empty
                // list). Surface it rather than silently no-op, so the
                // user sees *something* happened.
                switchFailedAccountId = account.id
                switchFailedMessage = "Account list not yet loaded from token-slayer — try again in a moment"
                return
            }
            switch await tokenSlayerCLI.switchAccount(target: target, binaryPath: binaryPath) {
            case .success:
                switchFailedAccountId = nil
                switchFailedMessage = nil
            case .failure(let error):
                switchFailedAccountId = account.id
                switchFailedMessage = Self.message(for: error)
            }
            await refreshFromSlayer(binaryPath: binaryPath, live: false)
            return
        }
        let succeeded = await nativeAccountSwitcher.switchTo(account: account)
        switchFailedAccountId = succeeded ? nil : account.id
        switchFailedMessage = nil
        await refreshUsageNow()
    }

    /// Slayer mode: launches `token-slayer tui` in Terminal — it owns its
    /// own add-account/login flow, so none of the native capture machinery
    /// below applies. Native mode is unchanged: snapshots the currently-live
    /// credentials as the pre-login baseline, then launches `claude /login`
    /// in Terminal. The resulting new login is picked up by
    /// `recheckReloginAccounts()` (popover-open + the ~60s captureTask
    /// ticker started in `start()`).
    func beginAddAccount() async {
        if let binaryPath = await resolveSlayerBinaryIfEnabled() {
            // Single-quoted: TerminalLauncher writes this verbatim as a line
            // in a zsh script, and an install path containing a space would
            // otherwise split into a bogus extra argument.
            TerminalLauncher.run("'\(binaryPath)' tui")
            return
        }
        await accountCapture.beginCapture()
        TerminalLauncher.run("claude /login")
    }

    /// Re-authenticates a flagged existing account. Switches it live first
    /// (via `switchAccount`, which no-ops for the plain slot == nil account —
    /// same guard the Switch button relies on) so `claude /login` renews the
    /// *target* account's credentials rather than whatever happens to be
    /// currently active, then snapshots that just-switched state as the
    /// capture baseline before launching the login.
    ///
    /// Baseline capture deliberately happens after the switch, not before:
    /// capturing the pre-switch credentials as the baseline would make the
    /// switch itself look like a completed login the instant the live item
    /// changes — well before the user ever reaches the browser hand-off —
    /// so the ~60s captureTask ticker or a popover reopen could clear
    /// `needsRelogin` against credentials that were never actually renewed.
    func beginRelogin(_ account: Account) async {
        if let binaryPath = await resolveSlayerBinaryIfEnabled() {
            // Single-quoted: TerminalLauncher writes this verbatim as a line
            // in a zsh script, and an install path containing a space would
            // otherwise split into a bogus extra argument.
            TerminalLauncher.run("'\(binaryPath)' tui")
            return
        }
        await switchAccount(account)
        await accountCapture.beginCapture()
        TerminalLauncher.run("claude /login")
    }

    /// Re-fetches only accounts flagged needs-relogin. Runs when the popover
    /// opens: after the user logs back in, the poll loop's failure backoff
    /// (every 8th cycle at 3+ failures) would otherwise keep the stale badge
    /// up for the better part of an hour. No-op in slayer mode: there's no
    /// native capture baseline to check, and `refreshUsageIfNeeded()`'s own
    /// popover-open `list --json` call already keeps `needsRelogin` current.
    func recheckReloginAccounts() async {
        guard await resolveSlayerBinaryIfEnabled() == nil else { return }
        if case .captured = await accountCapture.checkForNewLogin() {
            await refreshUsageNow()
        }
        let flagged = accounts.filter { usageStore.states[$0.id]?.needsRelogin == true }
        guard !flagged.isEmpty else { return }
        await usageStore.refresh(accounts: await usageInputs(flagged))
    }

    /// Fetches `sessions --json` and joins `billed_account` onto hook-based
    /// session rows by `session_id` — a small secondary annotation, not a
    /// replacement for the hook data. Called on popover open; the poll loop
    /// calls the `binaryPath:` overload directly since it's already resolved
    /// one. Clears to empty outside slayer mode so a toggle-off doesn't leave
    /// stale annotations on screen.
    func refreshSessionAnnotations() async {
        guard let binaryPath = await resolveSlayerBinaryIfEnabled() else {
            sessionBilledAccounts = [:]
            return
        }
        await refreshSessionAnnotations(binaryPath: binaryPath)
    }

    private func refreshSessionAnnotations(binaryPath: String) async {
        guard case .success(let doc) = await tokenSlayerCLI.sessions(binaryPath: binaryPath) else { return }
        sessionBilledAccounts = SlayerSessionJoin.billedAccounts(from: doc.sessions)
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

    /// Poll-cadence entry point. Slayer mode: one `status --json` call
    /// covers every account (no per-account backoff — that's a native-only
    /// concept for the per-account network fetcher), plus a `sessions --json`
    /// refresh for the billed-account annotation. Native mode is unchanged.
    private func pollOnce() async {
        if let binaryPath = await resolveSlayerBinaryIfEnabled() {
            await refreshFromSlayer(binaryPath: binaryPath, live: true)
            await refreshSessionAnnotations(binaryPath: binaryPath)
            return
        }
        accounts = resolveAccounts()
        let cycle = pollCycle
        pollCycle += 1
        let due = accounts.filter { account in
            let failures = usageStore.states[account.id]?.failureCount ?? 0
            return !UsageStore.shouldSkip(cycle: cycle, failureCount: failures)
        }
        guard !due.isEmpty else { return }
        await usageStore.refresh(accounts: await usageInputs(due))
    }

    /// Spends this launch's one *interactive* `LiveCredentialSelfHeal`
    /// attempt, if it hasn't been spent already — the caller-owned gate that
    /// `LiveCredentialSelfHeal.run`'s own doc comment says it needs, since
    /// its non-interactive `isTrusted` probe alone doesn't stop every call
    /// site below from retrying the *interactive* repair read forever under
    /// persistent distrust.
    ///
    /// Checked-and-set with no `await` between them, mirroring
    /// `refreshUsageIfNeeded()`'s `refreshInFlight` guard above: `start()`'s
    /// launch-time call, the wake observer, and the screen-unlock observer
    /// can all reach here, and wake+unlock firing together (e.g. waking a
    /// machine that also auto-unlocks) must not both win the one attempt.
    /// Every call after the first (from any site) still runs `run()` for its
    /// non-interactive `isTrusted` probe and diagnostic logging — only the
    /// interactive repair-read branch is actually skipped.
    private func attemptLiveCredentialSelfHeal() async {
        // Nothing native to re-trust when token-slayer owns the session: it
        // reads accounts/usage through its own CLI, so the live item's ACL is
        // irrelevant. Checked before the gate below so a slayer-mode launch
        // doesn't burn the one interactive attempt it will never use.
        guard await resolveSlayerBinaryIfEnabled() == nil else { return }
        let allowInteractive = !liveCredentialSelfHealAttempted
        if allowInteractive {
            liveCredentialSelfHealAttempted = true
        }
        _ = await LiveCredentialSelfHeal.run(
            diagnosticLog: paths.root.appendingPathComponent("native-switch.log"),
            allowInteractive: allowInteractive)
    }

    /// Pairs each account with its token via StatusBarCore's
    /// `TokenResolution` (see its doc comment for the isActive gating this
    /// replays). Each account's decision is additionally logged to
    /// `token-resolution.log` under `paths.root` — there to give the
    /// still-unexplained intermittent Keychain re-prompt real evidence: if
    /// the log from the exact cycle when the prompt fired shows
    /// `tokenSource=keychainFallback` alongside an unexpectedly nil orgUuid,
    /// that's useful context rather than leaving it a guess. Never logs a
    /// token value.
    ///
    /// Awaits `selfHealTask` first (a no-op once it's already finished, which
    /// it normally is well before any of this function's three call sites
    /// run) — see the comment where that task is created in `start()`. Then
    /// calls `attemptLiveCredentialSelfHeal()` on every invocation, not just
    /// at launch: for a native multi-account setup every account's
    /// `oauthURL` is a `/dev/null` placeholder (see `NativeAccountStore`), so
    /// the active account's token comes from the Keychain fallback on every
    /// single poll cycle, not just occasionally, and `claude` itself
    /// rewrites the shared `"Claude Code-credentials"` item via a plain
    /// `security add-generic-password -U` on its own login/refresh flows
    /// (see `LiveCredentialWriter`'s doc comment) — that resets the ACL to a
    /// default single-writer state that no longer trusts this app. But
    /// `attemptLiveCredentialSelfHeal()` only lets *one* of those calls
    /// (whichever gets there first this launch — here or an observer) run
    /// the actual *interactive* repair read; every other call, from here or
    /// anywhere else, only gets the non-interactive `isTrusted` probe. A poll
    /// cycle that hits distrust after the one attempt is spent still surfaces
    /// the resulting non-interactive Keychain failure the same way it always
    /// did — it just won't itself pop a permission dialog to fix it.
    ///
    /// Per-account vault self-heal deliberately does *not* run here: this
    /// function runs on `@MainActor` from the background poll timer, and
    /// vault self-heal's repair read is interactive — with N untrusted
    /// inactive accounts that would be N sequential blocking prompts fired by
    /// a timer rather than a user action. `NativeAccountSwitcher.switchTo`
    /// does that repair before every user-initiated switch (see its doc
    /// comment) instead. Tradeoff: an inactive account's usage may not
    /// resolve from the vault until the user switches to it once per launch.
    private func usageInputs(
        _ accounts: [Account]
    ) async -> [(account: Account, token: String?)] {
        _ = await selfHealTask?.value
        await attemptLiveCredentialSelfHeal()
        var diagnostics: [TokenResolutionDiagnostics.Entry] = []
        let result = accounts.map { account -> (account: Account, token: String?) in
            let (token, source) = TokenResolution.resolve(account: account)
            diagnostics.append(.init(accountId: account.id, isActive: account.isActive,
                                     organizationUuid: account.organizationUuid,
                                     source: source))
            return (account, token)
        }
        TokenResolutionDiagnostics.write(
            diagnostics, to: paths.root.appendingPathComponent("token-resolution.log"))
        return result
    }
}
