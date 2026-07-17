import Foundation
import Testing
@testable import StatusBarCore

private let now = Date(timeIntervalSince1970: 100_000)

private func session(_ state: SessionState, label: String? = nil,
                     busyFor: TimeInterval? = nil) -> SessionRecord {
    SessionRecord(sessionId: "s", state: state, label: label, cwd: "/tmp/proj",
                  startedAt: now.addingTimeInterval(-600),
                  busySince: busyFor.map { now.addingTimeInterval(-$0) }, updatedAt: now)
}

private func usage(five: Double, seven: Double) -> AccountUsageState {
    AccountUsageState(
        snapshot: UsageSnapshot(fiveHour: UsageWindow(utilization: five),
                                sevenDay: UsageWindow(utilization: seven),
                                fetchedAt: now),
        freshness: .fresh)
}

@Suite struct ElapsedTests {
    @Test func formats() {
        #expect(MenuBarText.elapsed(45) == "45s")
        #expect(MenuBarText.elapsed(192) == "3m 12s")
        #expect(MenuBarText.elapsed(3_840) == "1h 04m")
        #expect(MenuBarText.elapsed(0) == "0s")
    }
}

@Suite struct MenuBarTextTests {
    private func model(display: SessionRecord?, usage: AccountUsageState?,
                       style: DisplayStyle, showUsage: Bool = true,
                       showElapsed: Bool = true,
                       messageStyle: MessageStyle = MessageStyles.style(id: "classic"))
        -> MenuBarLabelModel {
        MenuBarText.model(display: display, usage: usage, style: style,
                          showUsage: showUsage, showElapsed: showElapsed,
                          yellowAt: 50, redAt: 80,
                          verb: "Pondering", messageStyle: messageStyle, now: now)
    }

    @Test func hidingElapsedDropsTimeFromActivity() {
        let tool = model(display: session(.tool, label: "Running", busyFor: 192),
                         usage: nil, style: .full, showElapsed: false)
        #expect(tool.activityText == "Running")
        let thinking = model(display: session(.thinking, busyFor: 45),
                             usage: nil, style: .full, showElapsed: false)
        #expect(thinking.activityText == "Pondering…")
    }

    @Test func toolStateShowsLabelAndElapsed() {
        let m = model(display: session(.tool, label: "Running", busyFor: 192),
                      usage: nil, style: .full)
        #expect(m.state == .tool)
        #expect(m.activityText == "Running · 3m 12s")
    }

    @Test func thinkingUsesVerb() {
        let m = model(display: session(.thinking, busyFor: 45), usage: nil, style: .full)
        #expect(m.activityText == "Pondering… · 45s")
    }

    @Test func waitingHasFixedText() {
        let m = model(display: session(.waiting, busyFor: 45), usage: nil, style: .full)
        #expect(m.activityText == "Waiting for you")
    }

    @Test func idleAndIconOnlyShowNoActivity() {
        #expect(model(display: session(.idle), usage: nil, style: .full).activityText == nil)
        #expect(model(display: nil, usage: nil, style: .full).activityText == nil)
        let m = model(display: session(.tool, label: "Running", busyFor: 10),
                      usage: usage(five: 71, seven: 29), style: .iconOnly)
        #expect(m.activityText == nil)
        #expect(m.usageText == nil)
    }

    @Test func usageTextPerStyle() {
        let u = usage(five: 70.6, seven: 29.2)
        #expect(model(display: nil, usage: u, style: .full).usageText == "5h 71% · 7d 29%")
        #expect(model(display: nil, usage: u, style: .percent).usageText == "71%")
        #expect(model(display: nil, usage: u, style: .full, showUsage: false).usageText == nil)
        #expect(model(display: nil, usage: nil, style: .full).usageText == nil)
    }

    @Test func compactShowsPercentOnlyNoActivity() {
        let m = model(display: session(.tool, label: "Running", busyFor: 10),
                      usage: usage(five: 70.6, seven: 29.2), style: .compact)
        #expect(m.activityText == nil)
        #expect(m.usageText == "71%")
        #expect(m.textLeading == false)
    }

    @Test func textFirstLeadsWithActivity() {
        let m = model(display: session(.tool, label: "Running", busyFor: 192),
                      usage: usage(five: 70.6, seven: 29.2), style: .textFirst)
        #expect(m.activityText == "Running · 3m 12s")
        #expect(m.usageText == "71%")
        #expect(m.textLeading == true)
    }

    @Test func onlyTextFirstLeadsWithText() {
        for style in [DisplayStyle.iconOnly, .compact, .percent, .full] {
            #expect(model(display: nil, usage: nil, style: style).textLeading == false)
        }
    }

    @Test func levelsComputedFromThresholds() {
        let m = model(display: nil, usage: usage(five: 85, seven: 55), style: .full)
        #expect(m.fiveHourLevel == .red)
        #expect(m.sevenDayLevel == .yellow)
        #expect(model(display: nil, usage: nil, style: .full).fiveHourLevel == nil)
    }

    @Test func usageLevelMatchesFiveHourForTextStyles() {
        // 5h red, 7d green — percent/compact/textFirst only surface the 5h
        // number, so usageLevel must track it, not the (greener) 7d figure.
        let u = usage(five: 85, seven: 20)
        #expect(model(display: nil, usage: u, style: .percent).usageLevel == .red)
        #expect(model(display: nil, usage: u, style: .compact).usageLevel == .red)
        #expect(model(display: nil, usage: u, style: .textFirst).usageLevel == .red)
    }

    @Test func usageLevelIsWorseOfBothForFullStyle() {
        // .full shows both numbers in one string, so usageLevel should be
        // whichever window is more severe, regardless of which one it is.
        #expect(model(display: nil, usage: usage(five: 30, seven: 85), style: .full).usageLevel == .red)
        #expect(model(display: nil, usage: usage(five: 85, seven: 30), style: .full).usageLevel == .red)
        #expect(model(display: nil, usage: usage(five: 60, seven: 55), style: .full).usageLevel == .yellow)
    }

    @Test func usageLevelNilWhenNoUsageOrIconOnly() {
        #expect(model(display: nil, usage: nil, style: .full).usageLevel == nil)
        #expect(model(display: nil, usage: usage(five: 85, seven: 20), style: .iconOnly).usageLevel == nil)
    }

    @Test func toolLabelThemedByStyle() {
        let m = model(display: session(.tool, label: "Editing", busyFor: 192),
                      usage: nil, style: .full,
                      messageStyle: MessageStyles.style(id: "rpg"))
        #expect(m.activityText == "Forging the blade · 3m 12s")
    }

    @Test func unknownToolLabelPassesThroughUnthemed() {
        // Capitalized raw tool names from the hook fallback (e.g. WebFetch)
        // are not in any style's map — they render as-is.
        let m = model(display: session(.tool, label: "WebFetch", busyFor: 45),
                      usage: nil, style: .full,
                      messageStyle: MessageStyles.style(id: "pirate"))
        #expect(m.activityText == "WebFetch · 45s")
    }

    @Test func missingLabelThemedAsWorking() {
        let m = model(display: session(.tool, busyFor: 45), usage: nil, style: .full,
                      messageStyle: MessageStyles.style(id: "gardening"))
        #expect(m.activityText == "Tending the garden · 45s")
    }

    @Test func waitingUsesStylePhrase() {
        let m = model(display: session(.waiting, busyFor: 45), usage: nil, style: .full,
                      messageStyle: MessageStyles.style(id: "cooking"))
        #expect(m.activityText == "Stomach's officially growling")
    }

    @Test func classicRendersByteIdenticalToV1() {
        let tool = model(display: session(.tool, label: "Editing", busyFor: 12),
                         usage: nil, style: .full)
        #expect(tool.activityText == "Editing · 12s")
        let waiting = model(display: session(.waiting, busyFor: 12), usage: nil, style: .full)
        #expect(waiting.activityText == "Waiting for you")
        let thinking = model(display: session(.thinking, busyFor: 12), usage: nil, style: .full)
        #expect(thinking.activityText == "Pondering… · 12s")
    }
}

@Suite struct ThinkingVerbsTests {
    @Test func has28UniqueVerbs() {
        #expect(ThinkingVerbs.all.count == 28)
        #expect(Set(ThinkingVerbs.all).count == 28)
    }

    @Test func neverRepeatsImmediately() {
        // rng always returns 0 -> would always pick index 0 without the no-repeat rule
        var cycler = VerbCycler(rng: { 0 })
        let first = cycler.next(from: ThinkingVerbs.all)
        let second = cycler.next(from: ThinkingVerbs.all)
        #expect(first != second)

        var random = VerbCycler()
        var previous = random.next(from: ThinkingVerbs.all)
        for _ in 0..<200 {
            let verb = random.next(from: ThinkingVerbs.all)
            #expect(verb != previous)
            #expect(ThinkingVerbs.all.contains(verb))
            previous = verb
        }
    }

    @Test func stalePreviousIndexIsForgottenOnSmallerPool() {
        // rng 0.99 picks the last index: 4 in the big pool — out of range for
        // the small pool. Must be treated as nil, never index out of bounds.
        var cycler = VerbCycler(rng: { 0.99 })
        let big = ["a", "b", "c", "d", "e"]
        #expect(cycler.next(from: big) == "e")
        let small = ["x", "y"]
        let pick = cycler.next(from: small)
        #expect(small.contains(pick))
    }

    @Test func singlePhrasePoolRepeatsWithoutCrashing() {
        var cycler = VerbCycler(rng: { 0 })
        #expect(cycler.next(from: ["only"]) == "only")
        #expect(cycler.next(from: ["only"]) == "only")
    }

    @Test func resetClearsNoRepeatMemory() {
        // rng 0 always picks index 0; after reset() the same phrase may repeat.
        var cycler = VerbCycler(rng: { 0 })
        let first = cycler.next(from: ThinkingVerbs.all)
        cycler.reset()
        #expect(cycler.next(from: ThinkingVerbs.all) == first)
    }
}
