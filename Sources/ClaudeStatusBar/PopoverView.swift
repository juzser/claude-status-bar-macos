import SwiftUI
import StatusBarCore

struct PopoverView: View {
    let appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                SessionsSection(sessions: appState.sessions, now: context.date)
                Divider()
                AccountsSection(accounts: appState.visibleAccounts,
                                states: appState.usageStore.states,
                                yellowAt: appState.yellowAt, redAt: appState.redAt,
                                now: context.date)
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
    }
}
