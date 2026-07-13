import SwiftUI
import Testing
@testable import ClaudeStatusBar
import StatusBarCore

@Suite struct MenuBarLabelViewEffectiveDarkTests {
    @Test func transparentFollowsColorScheme() {
        #expect(MenuBarLabelView.effectiveDark(backgroundStyle: .transparent, colorScheme: .light) == false)
        #expect(MenuBarLabelView.effectiveDark(backgroundStyle: .transparent, colorScheme: .dark) == true)
    }

    @Test func lightForcesLightContentRegardlessOfColorScheme() {
        #expect(MenuBarLabelView.effectiveDark(backgroundStyle: .light, colorScheme: .light) == false)
        #expect(MenuBarLabelView.effectiveDark(backgroundStyle: .light, colorScheme: .dark) == false)
    }

    @Test func darkForcesDarkContentRegardlessOfColorScheme() {
        #expect(MenuBarLabelView.effectiveDark(backgroundStyle: .dark, colorScheme: .light) == true)
        #expect(MenuBarLabelView.effectiveDark(backgroundStyle: .dark, colorScheme: .dark) == true)
    }
}
