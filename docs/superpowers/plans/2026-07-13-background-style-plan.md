# Background Style Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick a background behind the composited menu bar label — Transparent (default, today's behavior), Light, or Dark — via a new picker in Settings → General.

**Architecture:** A new `BackgroundStyle` enum (mirrors the existing `DisplayStyle` pattern) flows from a persisted `SettingsStore` property, through `MenuBarLabelView` (which also derives `effectiveDark` — the content-color override), into `LabelComposite.image`, which draws a capsule pill behind the composited label parts when the style isn't `.transparent`.

**Tech Stack:** Swift 6.0 (tools version), AppKit (`NSBezierPath`, `NSImage`), SwiftUI, swift-testing 0.12.0 (exact pin).

## Global Constraints

- `swift-tools-version: 6.0` — already set in `Package.swift`, do not change.
- swift-testing is pinned to **exact** `0.12.0` — only `@Test`, `@Suite`, `#expect`, `#require` are available. No newer swift-testing APIs.
- `BackgroundStyle` cases: `transparent`, `light`, `dark` (in that order), backed by `String` raw values matching the case names, `CaseIterable`, `Sendable`.
- `.transparent` output from `LabelComposite.image` must stay **byte-identical** in size to pre-feature behavior — verified by a pinned regression test, not a relative comparison.
- Pill padding: `CGFloat = 6`, horizontal only, each side. Canvas height never changes (`LabelComposite.height == 24`).
- Capsule radius = `height / 2` (i.e. `12`), via `NSBezierPath(roundedRect:xRadius:yRadius:)`.
- Fixed color constants (exact, no user configuration): light fill `#E5E5E5` / stroke `#C7C7C7`; dark fill `#3A3A3C` / stroke `#545456`. Stroke width `0.5pt`.
- `backgroundStyleRaw` UserDefaults key, default `"transparent"`; unknown persisted value falls back to `.transparent` via `?? .transparent` (never crashes, never rewrites the fallback back to defaults) — same convention as `displayStyleRaw`/`displayStyle`.
- Light/Dark background content color is **independent of system `colorScheme`**: Light always forces dark (black-ish) content, Dark always forces light (white-ish) content; only Transparent follows `colorScheme`.

---

### Task 1: `BackgroundStyle` enum

**Files:**
- Modify: `Sources/StatusBarCore/Display/MenuBarText.swift`
- Test: `Tests/StatusBarCoreTests/MenuBarTextTests.swift`

**Interfaces:**
- Produces: `public enum BackgroundStyle: String, CaseIterable, Sendable { case transparent, light, dark }` — consumed by Task 2 (`SettingsStore`), Task 3 (`LabelComposite`), Task 4 (`MenuBarLabelView`).

- [ ] **Step 1: Write the failing test**

Add this suite to the end of `Tests/StatusBarCoreTests/MenuBarTextTests.swift`:

```swift
@Suite struct BackgroundStyleTests {
    @Test func hasExactlyThreeCases() {
        #expect(BackgroundStyle.allCases.count == 3)
    }

    @Test func rawValuesRoundTrip() {
        for style in BackgroundStyle.allCases {
            #expect(BackgroundStyle(rawValue: style.rawValue) == style)
        }
    }

    @Test func rawValuesMatchCaseNames() {
        #expect(BackgroundStyle.transparent.rawValue == "transparent")
        #expect(BackgroundStyle.light.rawValue == "light")
        #expect(BackgroundStyle.dark.rawValue == "dark")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BackgroundStyleTests`
Expected: FAIL to build with "cannot find type 'BackgroundStyle' in scope"

- [ ] **Step 3: Write minimal implementation**

In `Sources/StatusBarCore/Display/MenuBarText.swift`, add this enum directly below the existing `DisplayStyle` enum (which currently reads `public enum DisplayStyle: String, CaseIterable, Sendable { case iconOnly, compact, percent, textFirst, full }`):

```swift
public enum BackgroundStyle: String, CaseIterable, Sendable {
    case transparent, light, dark
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BackgroundStyleTests`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Display/MenuBarText.swift Tests/StatusBarCoreTests/MenuBarTextTests.swift
git commit -m "feat: add BackgroundStyle enum"
```

---

### Task 2: `SettingsStore` persistence for `backgroundStyle`

**Files:**
- Modify: `Sources/StatusBarCore/Settings/SettingsStore.swift`
- Test: `Tests/StatusBarCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `BackgroundStyle` (Task 1).
- Produces: `SettingsStore.backgroundStyleRaw: String` (persisted, didSet writes to `UserDefaults`) and computed `SettingsStore.backgroundStyle: BackgroundStyle` (get/set) — consumed by Task 4 (`MenuBarLabelView`) and Task 5 (`SettingsView`, `ClaudeStatusBarApp`).

- [ ] **Step 1: Write the failing test**

In `Tests/StatusBarCoreTests/SettingsStoreTests.swift`, add `#expect(store.backgroundStyle == .transparent)` to the end of the `defaults()` test body (inside the existing `@Test func defaults()`):

```swift
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
        #expect(store.backgroundStyle == .transparent)
    }
```

Add `store.backgroundStyle = .dark` and the matching reload assertion to `persistsAcrossInstances()`:

```swift
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
        store.backgroundStyle = .dark

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
        #expect(reloaded.backgroundStyle == .dark)
    }
```

Add a new test function directly after `unknownDisplayStyleFallsBackToFull()`:

```swift
    @Test func unknownBackgroundStyleFallsBackToTransparent() {
        let defaults = makeDefaults()
        defaults.set("neon", forKey: "backgroundStyleRaw")
        #expect(SettingsStore(defaults: defaults).backgroundStyle == .transparent)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SettingsStoreTests`
Expected: FAIL to build with "value of type 'SettingsStore' has no member 'backgroundStyle'"

- [ ] **Step 3: Write minimal implementation**

In `Sources/StatusBarCore/Settings/SettingsStore.swift`, add a persisted property directly below `textAnimationEnabled`:

```swift
    public var backgroundStyleRaw: String {
        didSet { defaults.set(backgroundStyleRaw, forKey: "backgroundStyleRaw") }
    }
```

Add the computed property directly below `displayStyle`:

```swift
    public var backgroundStyle: BackgroundStyle {
        get { BackgroundStyle(rawValue: backgroundStyleRaw) ?? .transparent }
        set { backgroundStyleRaw = newValue.rawValue }
    }
```

In `init(defaults:)`, add this line directly below the `textAnimationEnabled = ...` line:

```swift
        backgroundStyleRaw = defaults.string(forKey: "backgroundStyleRaw") ?? BackgroundStyle.transparent.rawValue
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SettingsStoreTests`
Expected: PASS (all `SettingsStoreTests` suite tests, including the 3 new/modified ones)

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Settings/SettingsStore.swift Tests/StatusBarCoreTests/SettingsStoreTests.swift
git commit -m "feat: persist backgroundStyle in SettingsStore"
```

---

### Task 3: `ClaudeStatusBarTests` target + `LabelComposite` pill background

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/ClaudeStatusBar/LabelComposite.swift`
- Create: `Tests/ClaudeStatusBarTests/LabelCompositeTests.swift`

**Interfaces:**
- Consumes: `BackgroundStyle` (Task 1); `NSColor(hex:)` from `Sources/ClaudeStatusBar/ColorHex.swift` (existing, same target).
- Produces: `LabelComposite.image(model:icon:shimmerPhase:dark:normalColor:yellowColor:redColor:animateText:backgroundStyle:) -> NSImage` (new `backgroundStyle: BackgroundStyle` parameter, appended last) — consumed by Task 4 (`MenuBarLabelView`). Establishes the `ClaudeStatusBarTests` test target, reused by Task 4's tests.

**Note on the new test target:** the `ClaudeStatusBar` product is an `.executableTarget`; `testTarget(name: "ClaudeStatusBarTests", dependencies: ["ClaudeStatusBar", ...])` can `@testable import ClaudeStatusBar` from it exactly like `StatusBarCoreTests` does for `StatusBarCore` — this is a supported SwiftPM pattern, not a workaround.

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeStatusBarTests/LabelCompositeTests.swift`:

```swift
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

@Suite struct LabelCompositeBackgroundTests {
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LabelCompositeBackgroundTests`
Expected: FAIL to build — no `ClaudeStatusBarTests` target exists yet, and `LabelComposite.image` has no `backgroundStyle` parameter.

- [ ] **Step 3: Write minimal implementation**

In `Package.swift`, add a new test target as the last entry in the `targets:` array (directly after the existing `StatusBarCoreTests` target):

```swift
        .testTarget(
            name: "ClaudeStatusBarTests",
            dependencies: ["ClaudeStatusBar", "StatusBarCore", .product(name: "Testing", package: "swift-testing")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
```

The full `targets:` array becomes:

```swift
    targets: [
        .target(
            name: "StatusBarCore",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "ClaudeStatusBar",
            dependencies: ["StatusBarCore"],
            resources: [.copy("Resources/clawd")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "ClaudeStatusHook",
            dependencies: ["StatusBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "StatusBarCoreTests",
            dependencies: ["StatusBarCore", .product(name: "Testing", package: "swift-testing")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "ClaudeStatusBarTests",
            dependencies: ["ClaudeStatusBar", "StatusBarCore", .product(name: "Testing", package: "swift-testing")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
```

In `Sources/ClaudeStatusBar/LabelComposite.swift`, change the `image` function signature (add `backgroundStyle: BackgroundStyle` as the last parameter):

```swift
    static func image(model: MenuBarLabelModel, icon: ClawdIcon,
                      shimmerPhase: Double, dark: Bool, normalColor: NSColor,
                      yellowColor: NSColor, redColor: NSColor,
                      animateText: Bool, backgroundStyle: BackgroundStyle) -> NSImage {
```

Replace the tail of the function — from `guard !parts.isEmpty else { ... }` through the closing `}` of the `NSImage(size:flipped:)` closure — with:

```swift
        guard !parts.isEmpty else { return NSImage(size: NSSize(width: 1, height: height)) }

        let totalWidth = parts.map(\.image.size.width).reduce(0, +)
            + spacing * CGFloat(parts.count - 1)
        let pillPadding: CGFloat = 6
        let canvasWidth = backgroundStyle == .transparent ? totalWidth : totalWidth + pillPadding * 2
        let partsOriginX: CGFloat = backgroundStyle == .transparent ? 0 : pillPadding
        let size = NSSize(width: canvasWidth, height: height)
        return NSImage(size: size, flipped: false) { _ in
            if let (fill, stroke) = pillColors(for: backgroundStyle) {
                let pillRect = NSRect(x: 0, y: 0, width: canvasWidth, height: height)
                let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: height / 2, yRadius: height / 2)
                fill.setFill()
                pillPath.fill()
                stroke.setStroke()
                pillPath.lineWidth = 0.5
                pillPath.stroke()
            }
            var x: CGFloat = partsOriginX
            for part in parts {
                // Canvas is y-up; offsetY was measured in y-down (visual)
                // terms, so subtract it to nudge the artwork toward center.
                let y = (height - part.image.size.height) / 2 - part.offsetY
                part.image.draw(in: NSRect(x: x, y: y,
                                           width: part.image.size.width,
                                           height: part.image.size.height))
                x += part.image.size.width + spacing
            }
            return true
        }
    }

    /// Fixed reference colors approximating NSColor.windowBackgroundColor
    /// under each appearance — same "bake a known system color's sRGB hex"
    /// convention as normalColorHex/yellowColorHex/redColorHex. nil means no
    /// pill is drawn (.transparent), preserving pre-feature output exactly.
    private static func pillColors(for style: BackgroundStyle) -> (fill: NSColor, stroke: NSColor)? {
        switch style {
        case .transparent: return nil
        case .light: return (NSColor(hex: "#E5E5E5") ?? .white, NSColor(hex: "#C7C7C7") ?? .lightGray)
        case .dark: return (NSColor(hex: "#3A3A3C") ?? .black, NSColor(hex: "#545456") ?? .darkGray)
        }
    }
```

(This adds the `pillColors(for:)` helper as a new private static method and closes the `image` function as before — the rest of `LabelComposite.swift` below `image` is unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LabelCompositeBackgroundTests`
Expected: PASS (3 tests)

Then run the full suite once to confirm the new target didn't break anything else: `swift test`
Expected: all tests PASS (existing `StatusBarCoreTests` target is untouched by this task).

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/ClaudeStatusBar/LabelComposite.swift Tests/ClaudeStatusBarTests/LabelCompositeTests.swift
git commit -m "feat: draw background pill in LabelComposite"
```

---

### Task 4: `MenuBarLabelView.effectiveDark` + `backgroundStyle` threading

**Files:**
- Modify: `Sources/ClaudeStatusBar/MenuBarLabelView.swift`
- Create: `Tests/ClaudeStatusBarTests/MenuBarLabelViewTests.swift`

**Interfaces:**
- Consumes: `BackgroundStyle` (Task 1); `LabelComposite.image(...)` with `backgroundStyle:` parameter (Task 3); `ClaudeStatusBarTests` target (Task 3).
- Produces: `MenuBarLabelView.effectiveDark(backgroundStyle:colorScheme:) -> Bool` (static, pure — testable without rendering) and `MenuBarLabelView.backgroundStyle: BackgroundStyle` (instance property) — consumed by Task 5 (`ClaudeStatusBarApp.swift` call site).

- [ ] **Step 1: Write the failing test**

Create `Tests/ClaudeStatusBarTests/MenuBarLabelViewTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MenuBarLabelViewEffectiveDarkTests`
Expected: FAIL to build with "type 'MenuBarLabelView' has no member 'effectiveDark'"

- [ ] **Step 3: Write minimal implementation**

Replace the full contents of `Sources/ClaudeStatusBar/MenuBarLabelView.swift` with:

```swift
import AppKit
import SwiftUI
import StatusBarCore

struct MenuBarLabelView: View {
    let model: MenuBarLabelModel
    let icon: ClawdIcon
    var shimmerPhase: Double = 0
    let normalColor: NSColor
    let yellowColor: NSColor
    let redColor: NSColor
    let animateText: Bool
    let backgroundStyle: BackgroundStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The whole label is composited into one NSImage (LabelComposite):
        // MenuBarExtra flattens its label into the status button's single
        // image slot + title, so a multi-view HStack cannot control order
        // or keep more than one image.
        Image(nsImage: LabelComposite.image(model: model, icon: icon,
                                            shimmerPhase: shimmerPhase,
                                            dark: effectiveDark,
                                            normalColor: normalColor,
                                            yellowColor: yellowColor,
                                            redColor: redColor,
                                            animateText: animateText,
                                            backgroundStyle: backgroundStyle))
            .renderingMode(.original)
    }

    private var effectiveDark: Bool {
        Self.effectiveDark(backgroundStyle: backgroundStyle, colorScheme: colorScheme)
    }

    /// A Light background always pairs with dark content and a Dark
    /// background always pairs with light content, regardless of system
    /// appearance; only Transparent follows colorScheme. Static and pure so
    /// it's testable without constructing a SwiftUI environment.
    static func effectiveDark(backgroundStyle: BackgroundStyle, colorScheme: ColorScheme) -> Bool {
        switch backgroundStyle {
        case .transparent: colorScheme == .dark
        case .light: false
        case .dark: true
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MenuBarLabelViewEffectiveDarkTests`
Expected: PASS (3 tests)

Run: `swift build`
Expected: FAILS — `ClaudeStatusBarApp.swift` calls `MenuBarLabelView(...)` without the new required `backgroundStyle:` argument. This is expected; Task 5 fixes the call site. Confirm the failure is specifically a missing-argument error at that call site (not something else) before moving on.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/MenuBarLabelView.swift Tests/ClaudeStatusBarTests/MenuBarLabelViewTests.swift
git commit -m "feat: derive effectiveDark content color from backgroundStyle"
```

---

### Task 5: Settings picker + app wiring

**Files:**
- Modify: `Sources/ClaudeStatusBar/SettingsView.swift`
- Modify: `Sources/ClaudeStatusBar/ClaudeStatusBarApp.swift`

**Interfaces:**
- Consumes: `SettingsStore.backgroundStyle` (Task 2); `MenuBarLabelView.backgroundStyle` parameter (Task 4).
- Produces: nothing further downstream — this is the final task.

- [ ] **Step 1: Wire the picker into `GeneralTab`**

In `Sources/ClaudeStatusBar/SettingsView.swift`, in `GeneralTab.body`, add a new `Picker` directly below the existing `Picker("Display style", ...)` block (which ends with `.pickerStyle(.radioGroup)`) and above `Picker("Message style", ...)`:

```swift
            Picker("Background", selection: $settings.backgroundStyle) {
                Text("Transparent").tag(BackgroundStyle.transparent)
                Text("Light").tag(BackgroundStyle.light)
                Text("Dark").tag(BackgroundStyle.dark)
            }
            .pickerStyle(.segmented)
```

The surrounding `Form` block in `GeneralTab.body` reads, in order, after this change: `Toggle("Launch at login", ...)`, `Toggle("Show usage on menu bar", ...)`, `Toggle("Show elapsed time on menu bar", ...)`, `Toggle("Animate activity text", ...)`, `Picker("Display style", ...)`, the new `Picker("Background", ...)`, `Picker("Message style", ...)`, `Picker("Usage poll interval", ...)` — no other lines change.

- [ ] **Step 2: Thread `backgroundStyle` into the `MenuBarLabelView` call site**

In `Sources/ClaudeStatusBar/ClaudeStatusBarApp.swift`, add `backgroundStyle: appState.settings.backgroundStyle` as the last argument to the `MenuBarLabelView(...)` call:

```swift
            MenuBarLabelView(model: appState.labelModel,
                             icon: StatusIcon.icon(for: appState.display),
                             shimmerPhase: ShimmerText.phase(at: appState.tick),
                             normalColor: NSColor(hex: appState.settings.normalColorHex) ?? .systemGreen,
                             yellowColor: NSColor(hex: appState.settings.yellowColorHex) ?? .systemYellow,
                             redColor: NSColor(hex: appState.settings.redColorHex) ?? .systemRed,
                             animateText: appState.settings.textAnimationEnabled,
                             backgroundStyle: appState.settings.backgroundStyle)
```

- [ ] **Step 3: Build and run the full test suite**

Run: `swift build`
Expected: succeeds with no errors.

Run: `swift test`
Expected: all tests PASS across both `StatusBarCoreTests` and `ClaudeStatusBarTests` — no regressions in any pre-existing test.

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeStatusBar/SettingsView.swift Sources/ClaudeStatusBar/ClaudeStatusBarApp.swift
git commit -m "feat: add Background picker to Settings and wire it to the menu bar label"
```

- [ ] **Step 5: Manual smoke check (owner: Ser, not automatable)**

Build and launch the app (`make app` then `open dist/ClaudeStatusBar.app`, or `swift run ClaudeStatusBar` for a quick check), open Settings → General, and confirm:
- The "Background" segmented picker appears directly below "Display style" with Transparent/Light/Dark options.
- Switching between all three styles updates the menu bar label within ~1s (existing render cadence), with no crash.
- Transparent renders pixel-identical to before this feature (no visible pill).
- Light and Dark pills stay legible against both a light-appearance and a dark-appearance system menu bar.
- The pill grows/shrinks with activity text length changes (e.g. switching Display style or watching elapsed time tick up) without clipping or overlapping the real menu bar edge.
