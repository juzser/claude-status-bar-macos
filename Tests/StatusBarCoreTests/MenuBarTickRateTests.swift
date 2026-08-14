import Foundation
import Testing
@testable import StatusBarCore

@Suite("MenuBarTickRate")
struct MenuBarTickRateTests {
    @Test("an idle bar stops ticking entirely rather than idling at 1 Hz")
    func idleStopsTheTicker() {
        for style in DisplayStyle.allCases {
            #expect(MenuBarTickRate.milliseconds(busy: false, style: style) == nil)
        }
    }

    @Test("styles that show activity text tick at the animated cadence")
    func animatedStylesTickFast() {
        for style in [DisplayStyle.percent, .textFirst, .full] {
            #expect(MenuBarTickRate.milliseconds(busy: true, style: style)
                == MenuBarTickRate.animatedMilliseconds)
        }
    }

    /// The 1 Hz cases are exactly the styles `MenuBarText.model` refuses to
    /// build activity text for — asserted against that function rather than
    /// restated, so a style that starts (or stops) showing activity text
    /// can't silently keep the wrong tick rate.
    @Test("styles with no activity text fall back to the 1 Hz cadence")
    func staticStylesTickSlowly() {
        let busy = SessionRecord(sessionId: "s", state: .thinking, label: nil,
                                 cwd: "/tmp",
                                 startedAt: .init(timeIntervalSince1970: 0),
                                 busySince: .init(timeIntervalSince1970: 0),
                                 updatedAt: .init(timeIntervalSince1970: 10))
        for style in DisplayStyle.allCases {
            let model = MenuBarText.model(display: busy, usage: nil, style: style,
                                          showUsage: false, yellowAt: 50, redAt: 80,
                                          verb: "Thinking",
                                          messageStyle: MessageStyles.style(id: "classic"),
                                          now: .init(timeIntervalSince1970: 10))
            let expected = model.activityText == nil
                ? MenuBarTickRate.staticMilliseconds
                : MenuBarTickRate.animatedMilliseconds
            #expect(MenuBarTickRate.milliseconds(busy: true, style: style) == expected)
        }
    }

    @Test("the animated cadence stays fast enough to oversample the icon animation")
    func animatedCadenceOversamplesIconFrames() {
        // 8 baked frames swept over ShimmerText.period (1.6 s) = 200 ms per
        // frame. Anything slower than that would visibly drop icon frames.
        let msPerIconFrame = 1_600.0 / 8
        #expect(Double(MenuBarTickRate.animatedMilliseconds) < msPerIconFrame)
    }
}
