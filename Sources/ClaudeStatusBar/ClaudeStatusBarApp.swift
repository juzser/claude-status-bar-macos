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
            // Popover content arrives in Task 12; placeholder is functional.
            VStack(spacing: 8) {
                Text("Claude Status Bar").font(.headline)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding()
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
    }
}
