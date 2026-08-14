import AppKit
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

    // Nothing observable is read in this body — `appState` is handed to the
    // two child views and unwrapped there. That matters: this body used to
    // read the tick (via `appState.labelModel` and `appState.tick`), which
    // made the whole scene invalid on every animation frame. Measured on a
    // standalone MenuBarExtra probe over 5 s at the same cadence: 72 scene
    // body evaluations that way versus 1 with the reads pushed down into
    // `MenuBarLabelView`, which re-rendered the same 72 times either way.
    var body: some Scene {
        MenuBarExtra {
            PopoverView(appState: appState)
        } label: {
            MenuBarLabelView(appState: appState)
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
