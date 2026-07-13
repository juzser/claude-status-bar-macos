import AppKit
import Testing
@testable import ClaudeStatusBar
@testable import StatusBarCore

private let fixtureModel = MenuBarLabelModel(
    state: .thinking, activityText: "Working · 3s",
    usageText: "5h 71% · 7d 29%", fiveHourLevel: .green,
    sevenDayLevel: .green, usageLevel: .green, textLeading: false)

private func image(backgroundStyle: BackgroundStyle) -> NSImage {
    LabelComposite.image(model: fixtureModel, icon: .thinking, shimmerPhase: 0,
                         dark: false, normalColor: .systemGreen,
                         yellowColor: .systemYellow, redColor: .systemRed,
                         animateText: false, backgroundStyle: backgroundStyle)
}

// LabelComposite.frameCache/imageCache are static, non-thread-safe caches —
// fine in production (always touched from the main thread), but concurrent
// @Test execution races on them. Same fix as UsageClientTests' .serialized.
@Suite(.serialized) struct LabelCompositeBackgroundTests {
    @Test func transparentSizeMatchesPreFeatureBaseline() {
        let size = image(backgroundStyle: .transparent).size
        #expect(size.width == 210.0)
        #expect(size.height == 24.0)
    }

    @Test func lightAddsExactlyTwelvePointsOfWidth() {
        let transparent = image(backgroundStyle: .transparent).size
        let light = image(backgroundStyle: .light).size
        #expect(light.width == transparent.width + 12)
        #expect(light.height == transparent.height)
    }

    @Test func darkAddsExactlyTwelvePointsOfWidth() {
        let transparent = image(backgroundStyle: .transparent).size
        let dark = image(backgroundStyle: .dark).size
        #expect(dark.width == transparent.width + 12)
        #expect(dark.height == transparent.height)
    }
}
