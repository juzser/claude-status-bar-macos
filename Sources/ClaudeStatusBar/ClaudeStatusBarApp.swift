import SwiftUI
import StatusBarCore

@main
struct ClaudeStatusBarApp: App {
    @State private var appState = AppState()

    init() {
        // NSApp is still nil this early in the SwiftUI App lifecycle;
        // NSApplication.shared creates the app object on first access.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(appState: appState)
        } label: {
            MenuBarLabelView(model: appState.labelModel,
                             icon: StatusIcon.icon(for: appState.display),
                             shimmerPhase: ShimmerText.phase(at: appState.tick))
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
