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
                       style: DisplayStyle, showUsage: Bool = true) -> MenuBarLabelModel {
        MenuBarText.model(display: display, usage: usage, style: style,
                          showUsage: showUsage, yellowAt: 50, redAt: 80,
                          verb: "Pondering", now: now)
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

    @Test func levelsComputedFromThresholds() {
        let m = model(display: nil, usage: usage(five: 85, seven: 55), style: .full)
        #expect(m.fiveHourLevel == .red)
        #expect(m.sevenDayLevel == .yellow)
        #expect(model(display: nil, usage: nil, style: .full).fiveHourLevel == nil)
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
