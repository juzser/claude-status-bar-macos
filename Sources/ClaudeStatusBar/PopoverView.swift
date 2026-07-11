import SwiftUI
import StatusBarCore

struct PopoverView: View {
    let appState: AppState

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
                    SettingsLink { Text("Settings…") }
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(width: 320)
        }
    }
}
