import SwiftUI
import StatusBarCore

struct PopoverView: View {
    let appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                SessionsSection(sessions: appState.sessions,
                                titles: appState.sessionTitles, now: context.date)
                Divider()
                AccountsSection(accounts: appState.visibleAccounts,
                                states: appState.usageStore.states,
                                yellowAt: appState.yellowAt, redAt: appState.redAt,
                                normalColor: Color(hex: appState.settings.normalColorHex) ?? .green,
                                yellowColor: Color(hex: appState.settings.yellowColorHex) ?? .yellow,
                                redColor: Color(hex: appState.settings.redColorHex) ?? .red,
                                now: context.date,
                                onSwitch: { account in
                                    Task { await appState.switchAccount(account) }
                                })
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
        }
        // Runs on every popover open: clears a stale re-login badge right
        // after the user logs back in, instead of waiting out the poll
        // loop's failure backoff.
        .task { await appState.recheckReloginAccounts() }
    }
}
