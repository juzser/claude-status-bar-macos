# Message Styles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick a themed "message style" (Classic + 6 themes) that rewrites the menu bar's thinking/tool/waiting text, via a picker in Settings → General.

**Architecture:** Display-time theming. A new `MessageStyles` catalog in StatusBarCore maps canonical activity labels (baked into session files by the hook) to themed phrases at render time. `VerbCycler` generalizes to draw from any phrase pool, `MenuBarText.model` gains a `messageStyle` parameter, `SettingsStore` persists the chosen style id, and `AppState` re-rolls the thinking phrase on style switch. Hook binary, session-file format, popover (`SessionsSection`), and `StatusIcon` are untouched.

**Tech Stack:** Swift 6.0 toolchain in `.swiftLanguageMode(.v5)`, SwiftPM (no Xcode — CLT-only machine), macOS 14+, swift-testing pinned `exact: "0.12.0"`.

**Spec:** `docs/superpowers/specs/2026-07-11-message-styles-design.md` (commit `1075e8b`). One deliberate deviation: the spec names the new `MenuBarText.model` parameter `style:`, but that label already belongs to the existing `style: DisplayStyle` parameter — this plan names it `messageStyle:` instead.

## Global Constraints

- swift-testing is pinned `exact: "0.12.0"` — use ONLY `@Test`, `@Suite`, `#expect`, `#require`. No other swift-testing API (no traits, no parameterized `arguments:`, no `withKnownIssue`).
- Clean-room: every themed phrase is original and appears verbatim in this plan. Never copy code, strings, or verbs from vntrungld/claude-status-bar-kde or any other status-bar project.
- Every themed phrase (thinking, tool, waiting — all styles except `classic`) is exactly 3–4 whitespace-separated words. Transcribe phrases from this plan byte-exactly; do not "improve" them.
- Classic is the default style and must render byte-identically to v1: verbs from `ThinkingVerbs.all`, tool text `Editing · 12s`, waiting text `Waiting for you`.
- Untouched files/behavior: hook binary (`Sources/ClaudeStatusHook/`), `SessionReducer`, session-file format, `SessionsSection.swift` (popover keeps canonical text), `StatusIcon`.
- All code, comments, tests, and commit messages in English. Commit subjects imperative, ≤72 chars.
- Work on branch `feat/message-styles` (exists; base `main` @ `5db72a4`). Never push to main/master, never force-push.
- Test command: `swift test` from the repo root `/Users/ser/scatola/jobs/projects/claude-status-bar-macos`. Full suite (77 tests pre-existing) must pass at the end of every task.
- The shell's working directory may reset between commands — prefix every command with `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && `.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `Sources/StatusBarCore/Display/MessageStyles.swift` | **Create** (Task 1) | `MessageStyle` struct + the 7-style catalog + total `style(id:)` lookup |
| `Tests/StatusBarCoreTests/MessageStylesTests.swift` | **Create** (Task 1) | Catalog invariants + registry fallback tests |
| `Sources/StatusBarCore/Display/ThinkingVerbs.swift` | Modify (Task 2) | `VerbCycler.next(from:)` + `reset()`; `ThinkingVerbs.all` unchanged |
| `Sources/StatusBarCore/Settings/SettingsStore.swift` | Modify (Task 3) | Persisted `messageStyleId` + computed `messageStyle` |
| `Tests/StatusBarCoreTests/SettingsStoreTests.swift` | Modify (Task 3) | Persistence + fallback tests |
| `Sources/StatusBarCore/Display/MenuBarText.swift` | Modify (Task 4) | `messageStyle` parameter; themed `.tool`/`.waiting` text |
| `Tests/StatusBarCoreTests/MenuBarTextTests.swift` | Modify (Tasks 2, 4) | Cycler tests for new signature; theming + regression tests |
| `Sources/ClaudeStatusBar/AppState.swift` | Modify (Tasks 2, 4, 5) | Draw verbs from active style pool; `rerollThinkingPhrase()` |
| `Sources/ClaudeStatusBar/SettingsView.swift` | Modify (Task 6) | "Message style" picker in GeneralTab |

Note: `Sources/ClaudeStatusBar/` is the executable target — SwiftPM test targets cannot import it, so AppState/SettingsView changes are verified by `swift build` + the full core suite, not by new unit tests (same as v1).

---

### Task 1: MessageStyles catalog

**Files:**
- Create: `Sources/StatusBarCore/Display/MessageStyles.swift`
- Test: `Tests/StatusBarCoreTests/MessageStylesTests.swift` (create)

**Interfaces:**
- Consumes: `ThinkingVerbs.all` (existing `[String]`, 28 verbs).
- Produces: `public struct MessageStyle: Identifiable, Sendable { let id, name: String; let thinking: [String]; let tool: [String: String]; let waiting: String }`; `public enum MessageStyles { static let all: [MessageStyle]; static func style(id: String) -> MessageStyle }`. Later tasks rely on: `MessageStyles.style(id:)` being total (unknown id → classic), `all` ordered classic-first, and `tool` maps covering exactly the 7 canonical labels `Editing`, `Running`, `Reading`, `Searching`, `Browsing`, `Delegating`, `Working`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/StatusBarCoreTests/MessageStylesTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

private let canonicalLabels = ["Editing", "Running", "Reading", "Searching",
                               "Browsing", "Delegating", "Working"]

private func wordCount(_ phrase: String) -> Int {
    phrase.split(whereSeparator: \.isWhitespace).count
}

@Suite struct MessageStyleCatalogTests {
    @Test func lineupIsSevenStylesClassicFirst() {
        #expect(MessageStyles.all.map(\.id)
                == ["classic", "rpg", "gardening", "dumb", "scifi", "cooking", "pirate"])
    }

    @Test func idsAreUnique() {
        #expect(Set(MessageStyles.all.map(\.id)).count == MessageStyles.all.count)
    }

    @Test func everyStyleCoversAllCanonicalLabels() {
        for style in MessageStyles.all {
            #expect(Set(style.tool.keys) == Set(canonicalLabels), "\(style.id)")
            #expect(!style.thinking.isEmpty, "\(style.id)")
            #expect(!style.waiting.isEmpty, "\(style.id)")
        }
    }

    @Test func themedThinkingPoolsHaveTwelveUniquePhrases() {
        for style in MessageStyles.all where style.id != "classic" {
            #expect(style.thinking.count == 12, "\(style.id)")
            #expect(Set(style.thinking).count == 12, "\(style.id)")
        }
    }

    @Test func themedPhrasesAreThreeToFourWords() {
        for style in MessageStyles.all where style.id != "classic" {
            for phrase in style.thinking {
                #expect((3...4).contains(wordCount(phrase)), "\(style.id): \(phrase)")
            }
            for phrase in style.tool.values {
                #expect((3...4).contains(wordCount(phrase)), "\(style.id): \(phrase)")
            }
            #expect((3...4).contains(wordCount(style.waiting)), "\(style.id): \(style.waiting)")
        }
    }

    @Test func classicPreservesTodayExactly() {
        let classic = MessageStyles.style(id: "classic")
        #expect(classic.thinking == ThinkingVerbs.all)
        for label in canonicalLabels {
            #expect(classic.tool[label] == label)
        }
        #expect(classic.waiting == "Waiting for you")
    }

    @Test func unknownIdFallsBackToClassic() {
        #expect(MessageStyles.style(id: "nope").id == "classic")
        #expect(MessageStyles.style(id: "").id == "classic")
        #expect(MessageStyles.style(id: "pirate").id == "pirate")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test --filter MessageStyleCatalogTests`
Expected: BUILD FAILURE — `cannot find 'MessageStyles' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/StatusBarCore/Display/MessageStyles.swift`:

```swift
import Foundation

/// A themed set of menu bar phrases. `thinking` feeds `VerbCycler`;
/// `tool` maps the hook's canonical labels (Editing, Running, Reading,
/// Searching, Browsing, Delegating, Working) to themed phrases — unknown
/// labels render unthemed via `tool[label] ?? label`; `waiting` replaces
/// "Waiting for you". The popover keeps canonical text by design.
public struct MessageStyle: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let thinking: [String]
    public let tool: [String: String]
    public let waiting: String
}

public enum MessageStyles {
    public static let all: [MessageStyle] = [
        classic, rpg, gardening, dumb, scifi, cooking, pirate,
    ]

    /// Total lookup: an id persisted by a future version (or corrupted)
    /// must never crash the app — fall back to Classic, never write back.
    public static func style(id: String) -> MessageStyle {
        all.first { $0.id == id } ?? classic
    }

    static let classic = MessageStyle(
        id: "classic", name: "Classic",
        thinking: ThinkingVerbs.all,
        tool: ["Editing": "Editing", "Running": "Running", "Reading": "Reading",
               "Searching": "Searching", "Browsing": "Browsing",
               "Delegating": "Delegating", "Working": "Working"],
        waiting: "Waiting for you")

    static let rpg = MessageStyle(
        id: "rpg", name: "RPG",
        thinking: ["Consulting the oracle", "Rolling for wisdom",
                   "Studying ancient runes", "Brewing mana potions",
                   "Sharpening the sword", "Reading the prophecy",
                   "Charging the spell", "Plotting the quest",
                   "Leveling up wisdom", "Taming wild ideas",
                   "Gathering party buffs", "Deciphering old glyphs"],
        tool: ["Editing": "Forging the blade", "Running": "Casting the spell",
               "Reading": "Reading the scrolls", "Searching": "Scouting the dungeon",
               "Browsing": "Charting distant lands", "Delegating": "Summoning the party",
               "Working": "Grinding the XP"],
        waiting: "Awaiting your command")

    static let gardening = MessageStyle(
        id: "gardening", name: "Gardening",
        thinking: ["Watering the seedlings", "Sprouting new ideas",
                   "Composting stray thoughts", "Sowing fresh seeds",
                   "Sniffing the roses", "Grafting wild branches",
                   "Mulching the beds", "Sunning the sprouts",
                   "Repotting big ideas", "Trimming the hedges",
                   "Feeding the roots", "Warming the greenhouse"],
        tool: ["Editing": "Pruning the branches", "Running": "Turning the soil",
               "Reading": "Reading seed packets", "Searching": "Hunting for weeds",
               "Browsing": "Visiting the nursery", "Delegating": "Hiring garden gnomes",
               "Working": "Tending the garden"],
        waiting: "Ripe for picking")

    static let dumb = MessageStyle(
        id: "dumb", name: "Dumb",
        thinking: ["Making think happen", "Doing brain stuff",
                   "Vibing real hard", "Loading smart thoughts",
                   "Buffering big brain", "Thinking really hard",
                   "Consulting inner monologue", "Staring at ceiling",
                   "Rebooting the noggin", "Doing a ponder",
                   "Cooking hot takes", "Charging brain cells"],
        tool: ["Editing": "Typing many words", "Running": "Pressing big button",
               "Reading": "Looking at stuff", "Searching": "Finding the thing",
               "Browsing": "Surfing the webs", "Delegating": "Making friends work",
               "Working": "Doing the thing"],
        waiting: "Your turn buddy")

    static let scifi = MessageStyle(
        id: "scifi", name: "Sci-Fi",
        thinking: ["Computing warp trajectories", "Consulting ship AI",
                   "Calibrating the sensors", "Charging photon banks",
                   "Mapping wormhole routes", "Decoding alien signals",
                   "Aligning the antenna", "Simulating first contact",
                   "Cooling the reactor", "Plotting orbital burns",
                   "Syncing quantum clocks", "Scanning nebula clouds"],
        tool: ["Editing": "Rewiring the core", "Running": "Firing the thrusters",
               "Reading": "Scanning data banks", "Searching": "Probing deep space",
               "Browsing": "Hailing distant stations", "Delegating": "Deploying drone fleet",
               "Working": "Running ship diagnostics"],
        waiting: "Awaiting your orders")

    static let cooking = MessageStyle(
        id: "cooking", name: "Cooking",
        thinking: ["Tasting the broth", "Whisking fresh ideas",
                   "Reducing the sauce", "Proofing the dough",
                   "Caramelizing the onions", "Seasoning to taste",
                   "Simmering the stock", "Kneading raw thoughts",
                   "Toasting the spices", "Resting the roast",
                   "Glazing the tart", "Julienning the details"],
        tool: ["Editing": "Plating the dish", "Running": "Firing the stove",
               "Reading": "Reading the recipe", "Searching": "Raiding the pantry",
               "Browsing": "Shopping the market", "Delegating": "Calling sous chefs",
               "Working": "Prepping the ingredients"],
        waiting: "Order up, chef")

    static let pirate = MessageStyle(
        id: "pirate", name: "Pirate",
        thinking: ["Plotting the course", "Reading the stars",
                   "Studying the charts", "Counting gold doubloons",
                   "Eyeing the horizon", "Trimming the mainsail",
                   "Whispering to parrots", "Sniffing for treasure",
                   "Tying sailor knots", "Weathering the storm",
                   "Charting hidden coves", "Polishing the spyglass"],
        tool: ["Editing": "Patching the sails", "Running": "Firing the cannons",
               "Reading": "Studying the map", "Searching": "Digging for treasure",
               "Browsing": "Scanning the horizon", "Delegating": "Rallying the crew",
               "Working": "Swabbing the deck"],
        waiting: "Cap'n needs orders")
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test --filter MessageStyleCatalogTests`
Expected: PASS — 7 tests.

Then run the full suite: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test`
Expected: PASS — 84 tests (77 existing + 7 new).

- [ ] **Step 5: Commit**

```bash
cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && git add Sources/StatusBarCore/Display/MessageStyles.swift Tests/StatusBarCoreTests/MessageStylesTests.swift && git commit -m "feat: add MessageStyles catalog (7 themed phrase sets)"
```

---

### Task 2: Generalize VerbCycler to arbitrary phrase pools

**Files:**
- Modify: `Sources/StatusBarCore/Display/ThinkingVerbs.swift:13-31` (the `VerbCycler` struct)
- Modify: `Sources/ClaudeStatusBar/AppState.swift:45,82` (call sites — keep the package compiling)
- Test: `Tests/StatusBarCoreTests/MenuBarTextTests.swift` (the `ThinkingVerbsTests` suite)

**Interfaces:**
- Consumes: nothing new.
- Produces: `VerbCycler.next(from phrases: [String]) -> String` (mutating) and `VerbCycler.reset()` (mutating). The no-argument `next()` is REMOVED. `ThinkingVerbs.all` stays exactly as-is (public API, referenced by tests and the classic style). Task 5 relies on `next(from:)` + `reset()` with these exact names.

- [ ] **Step 1: Update existing tests and write the new failing tests**

In `Tests/StatusBarCoreTests/MenuBarTextTests.swift`, replace the entire `ThinkingVerbsTests` suite (currently the last suite in the file, lines 81–103) with:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test --filter ThinkingVerbsTests`
Expected: BUILD FAILURE — `extra argument 'from' in call` / `cannot find 'reset'` (the new signature doesn't exist yet).

- [ ] **Step 3: Write the implementation**

In `Sources/StatusBarCore/Display/ThinkingVerbs.swift`, replace the `VerbCycler` struct (keep `ThinkingVerbs` above it untouched):

```swift
/// Uniform random phrase picker that never repeats the previous pick.
/// Pool-agnostic: the caller passes the pool each draw, so switching
/// message styles mid-flight is safe. Precondition: `phrases` is non-empty
/// (guaranteed by the MessageStyles catalog invariant tests).
public struct VerbCycler {
    let rng: () -> Double
    var previousIndex: Int?

    public init(rng: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.rng = rng
    }

    public mutating func next(from phrases: [String]) -> String {
        // A remembered index may come from a different (larger) pool; and in
        // a one-phrase pool the no-repeat rule is unsatisfiable. Forget it.
        if let previous = previousIndex, previous >= phrases.count || phrases.count == 1 {
            previousIndex = nil
        }
        // Draw from the pool minus the previous pick, then map back to full indices.
        let poolSize = previousIndex == nil ? phrases.count : phrases.count - 1
        var index = min(Int(rng() * Double(poolSize)), poolSize - 1)
        if let previous = previousIndex, index >= previous { index += 1 }
        previousIndex = index
        return phrases[index]
    }

    public mutating func reset() {
        previousIndex = nil
    }
}
```

In `Sources/ClaudeStatusBar/AppState.swift`, update the two call sites so the executable target keeps compiling (still drawing from the classic pool — Task 5 switches this to the active style's pool):

Line 45 — change:
```swift
        self.currentVerb = verbCycler.next()
```
to:
```swift
        self.currentVerb = verbCycler.next(from: ThinkingVerbs.all)
```

Line 82 (inside `reaggregate()`) — change:
```swift
            currentVerb = verbCycler.next()
```
to:
```swift
            currentVerb = verbCycler.next(from: ThinkingVerbs.all)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test`
Expected: PASS — 87 tests (84 + 3 new cycler tests). `swift build` must also succeed (AppState call sites updated).

- [ ] **Step 5: Commit**

```bash
cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && git add Sources/StatusBarCore/Display/ThinkingVerbs.swift Sources/ClaudeStatusBar/AppState.swift Tests/StatusBarCoreTests/MenuBarTextTests.swift && git commit -m "feat: generalize VerbCycler to arbitrary phrase pools"
```

---

### Task 3: Persist message style choice in SettingsStore

**Files:**
- Modify: `Sources/StatusBarCore/Settings/SettingsStore.swift`
- Test: `Tests/StatusBarCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `MessageStyles.style(id:)` and `MessageStyle` from Task 1.
- Produces: `SettingsStore.messageStyleId: String` (persisted, UserDefaults key `"messageStyleId"`, default `"classic"`) and computed `SettingsStore.messageStyle: MessageStyle`. Tasks 4–6 rely on both names.

- [ ] **Step 1: Write the failing tests**

Add to the `SettingsStoreTests` suite in `Tests/StatusBarCoreTests/SettingsStoreTests.swift` (inside the suite, after `unknownDisplayStyleFallsBackToFull`):

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test --filter SettingsStoreTests`
Expected: BUILD FAILURE — `value of type 'SettingsStore' has no member 'messageStyleId'`.

- [ ] **Step 3: Write the implementation**

In `Sources/StatusBarCore/Settings/SettingsStore.swift`:

After the `hiddenAccounts` property (line 27), add:

```swift
    public var messageStyleId: String {
        didSet { defaults.set(messageStyleId, forKey: "messageStyleId") }
    }
```

After the computed `displayStyle` property (line 32), add:

```swift
    /// Total: an unknown persisted id falls back to Classic (never crashes,
    /// never writes the fallback back to defaults).
    public var messageStyle: MessageStyle {
        MessageStyles.style(id: messageStyleId)
    }
```

In `init`, after the `hiddenAccounts` line (line 41), add:

```swift
        messageStyleId = defaults.string(forKey: "messageStyleId") ?? "classic"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test`
Expected: PASS — 90 tests (87 + 3 new).

- [ ] **Step 5: Commit**

```bash
cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && git add Sources/StatusBarCore/Settings/SettingsStore.swift Tests/StatusBarCoreTests/SettingsStoreTests.swift && git commit -m "feat: persist message style choice in SettingsStore"
```

---

### Task 4: Theme MenuBarText output by message style

**Files:**
- Modify: `Sources/StatusBarCore/Display/MenuBarText.swift:15-36`
- Modify: `Sources/ClaudeStatusBar/AppState.swift:91-98` (`labelModel` call site)
- Test: `Tests/StatusBarCoreTests/MenuBarTextTests.swift`

**Interfaces:**
- Consumes: `MessageStyle`, `MessageStyles.style(id:)` (Task 1); `SettingsStore.messageStyle` (Task 3).
- Produces: `MenuBarText.model(display:usage:style:showUsage:yellowAt:redAt:verb:messageStyle:now:)` — the new `messageStyle: MessageStyle` parameter sits between `verb:` and `now:`. (Spec wording says the parameter is named `style:`, but that label is taken by the existing `style: DisplayStyle`; this plan names it `messageStyle:` — see the plan header.) `.tool` renders `messageStyle.tool[label] ?? label`; `.waiting` renders `messageStyle.waiting`; `.thinking` keeps using the pre-picked `verb` argument verbatim. Formats unchanged: `Phrase… · 12s` / `Phrase · 12s`.

- [ ] **Step 1: Update the test helper and write the new failing tests**

In `Tests/StatusBarCoreTests/MenuBarTextTests.swift`, replace the private `model(...)` helper inside the `MenuBarTextTests` suite (lines 32–37) with:

```swift
    private func model(display: SessionRecord?, usage: AccountUsageState?,
                       style: DisplayStyle, showUsage: Bool = true,
                       messageStyle: MessageStyle = MessageStyles.style(id: "classic"))
        -> MenuBarLabelModel {
        MenuBarText.model(display: display, usage: usage, style: style,
                          showUsage: showUsage, yellowAt: 50, redAt: 80,
                          verb: "Pondering", messageStyle: messageStyle, now: now)
    }
```

The classic default means every existing assertion in this suite (`"Running · 3m 12s"`, `"Pondering… · 45s"`, `"Waiting for you"`, …) keeps passing unchanged — that is the byte-identical regression check.

Then add these tests inside the `MenuBarTextTests` suite, after `levelsComputedFromThresholds`:

```swift
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
                      messageStyle: MessageStyles.style(id: "scifi"))
        #expect(m.activityText == "Running ship diagnostics · 45s")
    }

    @Test func waitingUsesStylePhrase() {
        let m = model(display: session(.waiting, busyFor: 45), usage: nil, style: .full,
                      messageStyle: MessageStyles.style(id: "cooking"))
        #expect(m.activityText == "Order up, chef")
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test --filter MenuBarTextTests`
Expected: BUILD FAILURE — `extra argument 'messageStyle' in call`.

- [ ] **Step 3: Write the implementation**

In `Sources/StatusBarCore/Display/MenuBarText.swift`, change the `model` signature (lines 16–19) to:

```swift
    public static func model(display: SessionRecord?, usage: AccountUsageState?,
                             style: DisplayStyle, showUsage: Bool,
                             yellowAt: Double, redAt: Double,
                             verb: String, messageStyle: MessageStyle,
                             now: Date) -> MenuBarLabelModel {
```

and the activity switch (lines 26–35) to:

```swift
            switch display.state {
            case .tool:
                let label = display.label ?? "Working"
                let phrase = messageStyle.tool[label] ?? label
                activity = time.map { "\(phrase) · \($0)" } ?? phrase
            case .thinking:
                activity = time.map { "\(verb)… · \($0)" } ?? "\(verb)…"
            case .waiting:
                activity = messageStyle.waiting
            case .idle:
                activity = nil
            }
```

In `Sources/ClaudeStatusBar/AppState.swift`, update `labelModel` (lines 94–97) to pass the active style:

```swift
        return MenuBarText.model(display: display, usage: activeUsage,
                                 style: displayStyle, showUsage: showUsageOnBar,
                                 yellowAt: yellowAt, redAt: redAt,
                                 verb: currentVerb, messageStyle: settings.messageStyle,
                                 now: Date())
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift test`
Expected: PASS — 95 tests (90 + 5 new). `swift build` must also succeed.

- [ ] **Step 5: Commit**

```bash
cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && git add Sources/StatusBarCore/Display/MenuBarText.swift Sources/ClaudeStatusBar/AppState.swift Tests/StatusBarCoreTests/MenuBarTextTests.swift && git commit -m "feat: theme menu bar tool/waiting text by message style"
```

---

### Task 5: AppState draws thinking phrases from the active style

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppState.swift:44-46,77-84` (init verb pick, `reaggregate()`, new method)

**Interfaces:**
- Consumes: `SettingsStore.messageStyle` (Task 3); `VerbCycler.next(from:)` / `reset()` (Task 2).
- Produces: `AppState.rerollThinkingPhrase()` (`@MainActor`, no arguments, no return) — Task 6's picker `.onChange` calls it by exactly this name.

Note: `AppState` lives in the executable target, which the test target cannot import — verification for this task is `swift build` + the full core suite staying green (same convention as v1).

- [ ] **Step 1: Write the implementation**

In `Sources/ClaudeStatusBar/AppState.swift`:

In `init` (lines 44–45), change:

```swift
        self.currentVerb = ThinkingVerbs.all[0]
        self.currentVerb = verbCycler.next(from: ThinkingVerbs.all)
```

to:

```swift
        self.currentVerb = ThinkingVerbs.all[0]
        self.currentVerb = verbCycler.next(from: self.settings.messageStyle.thinking)
```

(The `ThinkingVerbs.all[0]` placeholder stays: all stored properties must be initialized before `self.settings` can be read.)

In `reaggregate()` (line 82), change:

```swift
            currentVerb = verbCycler.next(from: ThinkingVerbs.all)
```

to:

```swift
            currentVerb = verbCycler.next(from: settings.messageStyle.thinking)
```

After `reaggregate()` (below line 84), add:

```swift
    /// Called when the user picks a new message style: forget the no-repeat
    /// memory (it indexes the old pool) and re-pick so a bar currently in
    /// .thinking re-renders with the new style at once.
    func rerollThinkingPhrase() {
        verbCycler.reset()
        currentVerb = verbCycler.next(from: settings.messageStyle.thinking)
    }
```

- [ ] **Step 2: Verify the build and suite**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift build && swift test`
Expected: build succeeds; 95 tests PASS (no new unit tests — executable target).

- [ ] **Step 3: Commit**

```bash
cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && git add Sources/ClaudeStatusBar/AppState.swift && git commit -m "feat: draw thinking phrases from the active message style"
```

---

### Task 6: Message style picker in Settings

**Files:**
- Modify: `Sources/ClaudeStatusBar/SettingsView.swift:11,25-54`

**Interfaces:**
- Consumes: `MessageStyles.all` (Task 1); `$settings.messageStyleId` (Task 3); `AppState.rerollThinkingPhrase()` (Task 5).
- Produces: nothing consumed by later tasks (final task).

- [ ] **Step 1: Write the implementation**

In `Sources/ClaudeStatusBar/SettingsView.swift`:

Line 11 — pass `appState` through to GeneralTab. Change:

```swift
            GeneralTab(settings: settings)
```

to:

```swift
            GeneralTab(appState: appState, settings: settings)
```

In `GeneralTab` (line 26), add the `appState` property above `settings`:

```swift
private struct GeneralTab: View {
    let appState: AppState
    @Bindable var settings: SettingsStore
```

Inside the `Form`, insert the picker between the "Display style" picker and the "Usage poll interval" picker (i.e. after line 48):

```swift
            Picker("Message style", selection: $settings.messageStyleId) {
                ForEach(MessageStyles.all) { style in
                    Text(style.name).tag(style.id)
                }
            }
            .onChange(of: settings.messageStyleId) {
                // Instant feedback: a bar currently in .thinking re-renders
                // now; tool/waiting text re-themes on the next TimelineView
                // tick (≤1 s).
                appState.rerollThinkingPhrase()
            }
```

- [ ] **Step 2: Verify the build and suite**

Run: `cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && swift build && swift test`
Expected: build succeeds; 95 tests PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos && git add Sources/ClaudeStatusBar/SettingsView.swift && git commit -m "feat: add Message style picker to Settings General tab"
```

---

## Verification (whole feature)

- `swift test` — 95 tests pass.
- `bash scripts/hook-integration-test.sh` — 11 checks pass (hook untouched; this proves it).
- `git diff main --stat` touches ONLY: `MessageStyles.swift` (new), `MessageStylesTests.swift` (new), `ThinkingVerbs.swift`, `MenuBarText.swift`, `SettingsStore.swift`, `AppState.swift`, `SettingsView.swift`, `MenuBarTextTests.swift`, `SettingsStoreTests.swift`, plus `docs/superpowers/`. Anything else (hook, SessionRecord, SessionsSection, StatusIcon) is a defect.
- Manual (post-merge, user-owned): pick "Pirate" in Settings → General while a Claude session runs; the bar switches to pirate phrases immediately during thinking, within 1 s otherwise; popover text stays canonical.
