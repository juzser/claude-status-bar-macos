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
        #expect(store.showElapsedOnBar == true)
        #expect(store.displayStyle == .full)
        #expect(store.pollMinutes == 5)
        #expect(store.yellowAt == 50)
        #expect(store.redAt == 80)
        #expect(store.hiddenAccounts.isEmpty)
        #expect(store.normalColorHex == "#34C759")
        #expect(store.yellowColorHex == "#FFCC00")
        #expect(store.redColorHex == "#FF3B30")
        #expect(store.textAnimationEnabled == true)
    }

    @Test func persistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.showUsageOnBar = false
        store.showElapsedOnBar = false
        store.displayStyle = .percent
        store.pollMinutes = 15
        store.yellowAt = 40
        store.redAt = 90
        store.hiddenAccounts = ["slot-2"]
        store.normalColorHex = "#112233"
        store.yellowColorHex = "#445566"
        store.redColorHex = "#778899"
        store.textAnimationEnabled = false

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.showUsageOnBar == false)
        #expect(reloaded.showElapsedOnBar == false)
        #expect(reloaded.displayStyle == .percent)
        #expect(reloaded.pollMinutes == 15)
        #expect(reloaded.yellowAt == 40)
        #expect(reloaded.redAt == 90)
        #expect(reloaded.hiddenAccounts == ["slot-2"])
        #expect(reloaded.normalColorHex == "#112233")
        #expect(reloaded.yellowColorHex == "#445566")
        #expect(reloaded.redColorHex == "#778899")
        #expect(reloaded.textAnimationEnabled == false)
    }

    @Test func unknownDisplayStyleFallsBackToFull() {
        let defaults = makeDefaults()
        defaults.set("hologram", forKey: "displayStyleRaw")
        #expect(SettingsStore(defaults: defaults).displayStyle == .full)
    }

    @Test func messageStyleDefaultsToClassic() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.messageStyleId == "classic")
        #expect(store.messageStyle.id == "classic")
    }

    @Test func messageStyleIdPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.messageStyleId = "pirate"
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.messageStyleId == "pirate")
        #expect(reloaded.messageStyle.id == "pirate")
    }

    @Test func unknownMessageStyleIdResolvesToClassicWithoutWriteBack() {
        let defaults = makeDefaults()
        defaults.set("vaporwave", forKey: "messageStyleId")
        let store = SettingsStore(defaults: defaults)
        #expect(store.messageStyle.id == "classic")
        // The raw value is preserved — never rewritten to "classic".
        #expect(store.messageStyleId == "vaporwave")
        #expect(defaults.string(forKey: "messageStyleId") == "vaporwave")
    }

    @Test func languageDefaultsToEnglish() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.languageRaw == "english")
        #expect(store.language == .english)
    }

    @Test func languagePersistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.language = .vietnamese
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.languageRaw == "vietnamese")
        #expect(reloaded.language == .vietnamese)
    }

    @Test func unknownLanguageRawFallsBackToEnglishWithoutWriteBack() {
        let defaults = makeDefaults()
        defaults.set("klingon", forKey: "languageRaw")
        let store = SettingsStore(defaults: defaults)
        #expect(store.language == .english)
        // The raw value is preserved — never rewritten to "english".
        #expect(store.languageRaw == "klingon")
        #expect(defaults.string(forKey: "languageRaw") == "klingon")
    }

    @Test func messageStyleReflectsLanguage() {
        let store = SettingsStore(defaults: makeDefaults())
        store.messageStyleId = "pirate"
        #expect(store.messageStyle.waiting == "Compass points to you")
        store.language = .vietnamese
        #expect(store.messageStyle.waiting == "La bàn chỉ bạn")
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
