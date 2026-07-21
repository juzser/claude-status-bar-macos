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
    /// 1 Hz heartbeat for the menu bar elapsed counter; advances only while busy.
    private(set) var tick = Date()
    private(set) var updateAvailable: ReleaseInfo?
    let usageStore: UsageStore
    let paths: AppPaths

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
    /// Stored (not fire-and-forget) so `usageInputs(_:)` can await it before
    /// the first real Keychain read of a launch — see its assignment in
    /// `start()` for why that ordering matters.
    private var selfHealTask: Task<Bool, Never>?
    /// Kept only so the observer could be removed later; nothing currently
    /// does, matching the other loop `Task`s in `start()` which also run for
    /// the app's lifetime with no explicit teardown.
    private var wakeObserver: NSObjectProtocol?

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
        accounts = resolveAccounts()
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
        selfHealTask = Task {
            await LiveCredentialSelfHeal.run(diagnosticLog: paths.root.appendingPathComponent("native-switch.log"))
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
                _ = await LiveCredentialSelfHeal.run(diagnosticLog: self.paths.root.appendingPathComponent("native-switch.log"))
                // Waking is also a sharp signal that usage data may be
                // stale (the poll loop paused for the whole sleep). Throttled
                // like the popover-open trigger — see refreshUsageIfNeeded().
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
        accounts = resolveAccounts()
        await usageStore.refresh(accounts: await usageInputs(accounts))
    }

    /// Popover-open and wake-from-sleep both call this instead of
    /// `refreshUsageNow()` directly: it skips the refresh when
    /// `UsageStore.shouldRefresh` says the last successful fetch is still
    /// recent, so neither trigger can hammer the API by firing repeatedly
    /// (popover reopened, laptop waking in quick succession). The throttle
    /// window itself is decided in StatusBarCore (testable); a throttled-in
    /// call still goes through the normal `refreshUsageNow()` path, so the
    /// existing per-account failure backoff still applies.
    func refreshUsageIfNeeded() async {
        guard usageStore.shouldRefresh() else { return }
        await refreshUsageNow()
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

    /// Switches the active account via NativeAccountSwitcher, then
    /// re-resolves accounts and refreshes usage so isActive/usage bars
    /// reflect the switch immediately. No-op for the plain default account
    /// (slot == nil) — it has nothing to switch to, and the UI never shows
    /// a Switch button for it (see AccountsSection.swift).
    func switchAccount(_ account: Account) async {
        guard account.slot != nil else { return }
        let succeeded = await nativeAccountSwitcher.switchTo(account: account)
        switchFailedAccountId = succeeded ? nil : account.id
        await refreshUsageNow()
    }

    /// Snapshots the currently-live credentials as the pre-login baseline,
    /// then launches `claude /login` in Terminal. The resulting new login
    /// is picked up by `recheckReloginAccounts()` (popover-open + the
    /// ~60s captureTask ticker started in `start()`).
    func beginAddAccount() async {
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
        await switchAccount(account)
        await accountCapture.beginCapture()
        TerminalLauncher.run("claude /login")
    }

    /// Re-fetches only accounts flagged needs-relogin. Runs when the popover
    /// opens: after the user logs back in, the poll loop's failure backoff
    /// (every 8th cycle at 3+ failures) would otherwise keep the stale badge
    /// up for the better part of an hour.
    func recheckReloginAccounts() async {
        if case .captured = await accountCapture.checkForNewLogin() {
            await refreshUsageNow()
        }
        let flagged = accounts.filter { usageStore.states[$0.id]?.needsRelogin == true }
        guard !flagged.isEmpty else { return }
        await usageStore.refresh(accounts: await usageInputs(flagged))
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
    /// runs a *fresh* `LiveCredentialSelfHeal.run` on every call, not just at
    /// launch: for a native multi-account setup every account's `oauthURL`
    /// is a `/dev/null` placeholder (see `NativeAccountStore`), so the active
    /// account's token comes from the Keychain fallback on every single poll
    /// cycle, not just occasionally. `claude` itself rewrites the shared
    /// `"Claude Code-credentials"` item via a plain `security
    /// add-generic-password -U` on its own login/refresh flows (see
    /// `LiveCredentialWriter`'s doc comment) — that resets the ACL to a
    /// default single-writer state that no longer trusts this app, and
    /// nothing repaired that mid-session before this change, since self-heal
    /// only ran once per launch. `run` itself stays cheap when trust is
    /// intact — it probes non-interactively via `isTrusted` and only
    /// rewrites the ACL when that probe fails — so calling it here doesn't
    /// re-litigate the "not on a timer" concern in its own doc comment; it
    /// only pays the ACL-rewrite cost exactly when an external reset has
    /// actually happened, right before the read that would otherwise pop a
    /// permission dialog.
    private func usageInputs(
        _ accounts: [Account]
    ) async -> [(account: Account, token: String?)] {
        _ = await selfHealTask?.value
        _ = await LiveCredentialSelfHeal.run(
            diagnosticLog: paths.root.appendingPathComponent("native-switch.log"))
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
