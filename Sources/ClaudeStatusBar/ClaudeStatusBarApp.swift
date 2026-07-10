import SwiftUI
import StatusBarCore

@main
struct ClaudeStatusBarApp: App {
    @State private var appState = AppState()

    init() {
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(appState: appState)
        } label: {
            // TimelineView ticks the elapsed counter while a session is busy.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                MenuBarLabelView(model: appState.labelModel,
                                 icon: StatusIcon.icon(for: appState.display))
            }
            .onAppear {
                appState.start()
                Task { await appState.refreshUsageNow() }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState, settings: appState.settings)
        }
    }
}
