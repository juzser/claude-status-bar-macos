import SwiftUI
import StatusBarCore

struct PopoverView: View {
    let appState: AppState
    @Environment(\.openSettings) private var openSettings
    /// Replaces a `TimelineView(.periodic(from: .now, by: 1))` — the schedule
    /// `CLAUDE.md` warns about, re-anchored to `.now` on every render — with a
    /// `.task`-driven clock that SwiftUI stops when the popover closes. See
    /// `PopoverClock`.
    @State private var clock = PopoverClock()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let release = appState.updateAvailable {
                Text("Update available: \(release.tagName)")
                    .font(.caption).foregroundStyle(.orange)
            }
            SessionsSection(sessions: appState.sessions,
                            titles: appState.sessionTitles,
                            billedAccounts: appState.sessionBilledAccounts, now: clock.now)
            Divider()
            AccountsSection(accounts: appState.visibleAccounts,
                            states: appState.usageStore.states,
                            yellowAt: appState.yellowAt, redAt: appState.redAt,
                            normalColor: .cached(hex: appState.settings.normalColorHex) ?? .green,
                            yellowColor: .cached(hex: appState.settings.yellowColorHex) ?? .yellow,
                            redColor: .cached(hex: appState.settings.redColorHex) ?? .red,
                            now: clock.now,
                            switchFailedAccountId: appState.switchFailedAccountId,
                            switchFailedMessage: appState.switchFailedMessage,
                            onSwitch: { account in
                                Task { await appState.switchAccount(account) }
                            },
                            onRelogin: { account in
                                Task { await appState.beginRelogin(account) }
                            },
                            onAddAccount: { Task { await appState.beginAddAccount() } })
            Divider()
            HStack {
                Button("Refresh") {
                    Task { await appState.refreshUsageNow() }
                }
                Spacer()
                Button("Settings…") {
                    // SettingsLink silently creates no window from a
                    // MenuBarExtra popover while the app is an inactive
                    // accessory (macOS 26). Activate first, then open.
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 320)
        // Ticks the relative timestamps above at 1 Hz, and only while the
        // popover is open — SwiftUI cancels `.task` on close.
        .task { await clock.run() }
        // Runs on every popover open: clears a stale re-login badge right
        // after the user logs back in, instead of waiting out the poll
        // loop's failure backoff.
        .task { await appState.recheckReloginAccounts() }
        // Also runs on every popover open, throttled (see
        // refreshUsageIfNeeded()) so a quickly reopened popover shows
        // current usage instead of waiting out the poll interval.
        .task { await appState.refreshUsageIfNeeded() }
        // Slayer-mode session annotation (billed_account per session); a
        // cheap no-op call in native mode.
        .task { await appState.refreshSessionAnnotations() }
    }
}
