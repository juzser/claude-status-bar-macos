import Foundation
import Testing
@testable import StatusBarCore

@MainActor @Suite struct SettingsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "settings-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaults() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.showUsageOnBar == true)
        #expect(store.displayStyle == .full)
        #expect(store.pollMinutes == 5)
        #expect(store.yellowAt == 50)
        #expect(store.redAt == 80)
        #expect(store.hiddenAccounts.isEmpty)
    }

    @Test func persistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.showUsageOnBar = false
        store.displayStyle = .percent
        store.pollMinutes = 15
        store.yellowAt = 40
        store.redAt = 90
        store.hiddenAccounts = ["slot-2"]

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.showUsageOnBar == false)
        #expect(reloaded.displayStyle == .percent)
        #expect(reloaded.pollMinutes == 15)
        #expect(reloaded.yellowAt == 40)
        #expect(reloaded.redAt == 90)
        #expect(reloaded.hiddenAccounts == ["slot-2"])
    }

    @Test func unknownDisplayStyleFallsBackToFull() {
        let defaults = makeDefaults()
        defaults.set("hologram", forKey: "displayStyleRaw")
        #expect(SettingsStore(defaults: defaults).displayStyle == .full)
    }
}

@Suite struct HookLocatorTests {
    @Test func hookBinarySitsNextToAppExecutable() {
        let app = URL(fileURLWithPath: "/Applications/ClaudeStatusBar.app/Contents/MacOS/ClaudeStatusBar")
        #expect(defaultHookBinary(appExecutable: app)?.path
                == "/Applications/ClaudeStatusBar.app/Contents/MacOS/claude-status-hook")
        #expect(defaultHookBinary(appExecutable: nil) == nil)
    }
}
