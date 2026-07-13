# Background Style — Design

**Date:** 2026-07-13
**Status:** Approved pending user spec review
**Repo:** claude-status-bar-macos (base: main @ fe931ff)

## Goal

Let the user pick a background behind the composited menu bar label —
**Transparent** (today's behavior, default), **Light**, or **Dark** — so the
bar can stay legible against busy wallpaper or a translucent menu bar,
independent of the system's light/dark appearance. The picker lives in
Settings → General, next to "Display style".

## Background (current pipeline)

- `LabelComposite.image(...)` bakes the entire label — activity text, Clawd
  icon, usage % — into **one** `NSImage`. This is required: a
  `MenuBarExtra` label is flattened into the status button's single image
  slot plus title, so a multi-view `HStack` can neither control part order
  nor keep more than one image. Compositing sidesteps the slots entirely.
- `MenuBarLabelView` reads `@Environment(\.colorScheme)` and passes
  `dark: colorScheme == .dark` into `LabelComposite.image`. `dark` drives
  content color: `ShimmerText.plain`/`.image` render white text/icon tint
  when `dark == true`, black when `false` — i.e. `dark` already means
  "render for a dark background," not "system is in dark mode." Today the
  two happen to be the same value.
- The composited image has no background of its own — it draws straight
  through to the real menu bar, which is why "transparent" is the existing,
  unnamed default.

## Decisions (from brainstorming)

1. **Scope: a pill behind the whole label.** The background sits behind
   the entire composited label (icon + activity text + usage %), not
   behind individual parts. Transparent means no background at all — pixel
   output identical to pre-feature behavior — and stays the default.
2. **Content color syncs to the chosen background, not to system
   appearance.** Light background forces dark content; Dark background
   forces light content; Transparent keeps today's auto-detect
   (`colorScheme == .dark`). This reuses the existing `dark:` parameter
   semantics in `LabelComposite`/`ShimmerText` — no new color-override
   mechanism needed.
3. **Shape: full capsule.** Fully rounded (radius = label height / 2),
   hugging the label's existing 24pt height with **horizontal-only**
   padding. Never taller than today's label, so it cannot clip against the
   menu bar's fixed content height.
4. **Colors: fixed, not user-configurable.** No new `ColorPicker`. Two
   literal hex constants (one per style), chosen to approximate
   `NSColor.windowBackgroundColor` under each appearance — same convention
   `normalColorHex`/`yellowColorHex`/`redColorHex` already use (baking a
   known system color's sRGB hex rather than resolving it live).

## Architecture

`BackgroundStyle` — new enum alongside `DisplayStyle` in
`Sources/StatusBarCore/Display/MenuBarText.swift` (no new file; `DisplayStyle`
already lives there and is this small):

```swift
public enum BackgroundStyle: String, CaseIterable, Sendable {
    case transparent, light, dark
}
```

Touched components (no other new files):

- **`SettingsStore`** — new persisted property `backgroundStyleRaw: String`
  (UserDefaults key `backgroundStyleRaw`, default `"transparent"`) +
  computed `backgroundStyle: BackgroundStyle`, same get/set pattern as
  `displayStyle`:
  ```swift
  public var backgroundStyle: BackgroundStyle {
      get { BackgroundStyle(rawValue: backgroundStyleRaw) ?? .transparent }
      set { backgroundStyleRaw = newValue.rawValue }
  }
  ```
- **`MenuBarLabelView`** — gains `let backgroundStyle: BackgroundStyle`. The
  literal `dark: colorScheme == .dark` passed to `LabelComposite.image` is
  replaced by a computed property:
  ```swift
  private var effectiveDark: Bool {
      switch backgroundStyle {
      case .transparent: colorScheme == .dark
      case .light: false
      case .dark: true
      }
  }
  ```
  `effectiveDark` is passed as `dark:`, and `backgroundStyle` is passed as
  a new parameter, into `LabelComposite.image`.
- **`LabelComposite.image`** — gains a `backgroundStyle: BackgroundStyle`
  parameter. Current behavior (compute `parts`, `totalWidth`, draw at
  origin) is reached unchanged when `backgroundStyle == .transparent` —
  byte-identical output, verified by regression test. Otherwise, after
  computing `parts`/`totalWidth` as today:
  - `pillPadding: CGFloat = 6` (horizontal only, each side; no change to
    vertical sizing — canvas height stays `height` = 24).
  - Canvas width becomes `totalWidth + pillPadding * 2`.
  - Fill a capsule path first —
    `NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: canvasWidth, height: height), xRadius: height / 2, yRadius: height / 2)`
    — with the style's fixed background color, then stroke it at 0.5pt in
    a slightly higher-contrast tint of the same color (keeps the pill
    legible when the real menu bar itself is translucent and near the same
    tone).
  - Draw `parts` shifted right by `pillPadding` (unchanged inter-part
    layout otherwise).
  - Fixed color constants (reference values — confirm visually against a
    real light/dark menu bar during implementation and adjust if contrast
    is poor; follow the same "bake a concrete hex, note what it
    approximates" convention as `normalColorHex`'s doc comment):
    - light: fill `#E5E5E5`, stroke `#C7C7C7`
    - dark: fill `#3A3A3C`, stroke `#545456`
- **`SettingsView.swift` (`GeneralTab`)** — new picker directly below
  "Display style":
  ```swift
  Picker("Background", selection: $settings.backgroundStyle) {
      Text("Transparent").tag(BackgroundStyle.transparent)
      Text("Light").tag(BackgroundStyle.light)
      Text("Dark").tag(BackgroundStyle.dark)
  }
  .pickerStyle(.segmented)
  ```
- **`ClaudeStatusBarApp.swift`** — threads
  `backgroundStyle: appState.settings.backgroundStyle` into the
  `MenuBarLabelView(...)` call site.

Untouched: `ShimmerText`, `StatusIcon`, message styles, threshold colors,
popover (`PopoverView`/`SessionsSection` keep their own native window
background — this feature only affects the menu bar label).

## Behavior

- Transparent (default) renders pixel-identical to pre-feature output —
  same canvas size, same part layout, same `dark` source (`colorScheme`).
- Switching style takes effect on the next render tick (≤1s, existing
  cadence) — no re-roll needed (unlike message styles, background doesn't
  touch any cycling/random state).
- Pill width tracks content width automatically, same as today's
  transparent canvas, just wider by `pillPadding * 2`.
- Light/Dark background modes intentionally override `colorScheme`-driven
  content color rather than follow it — a Dark background always pairs
  with light content, regardless of whether the system is in light or dark
  mode.

## Error handling

- `BackgroundStyle(rawValue:) ?? .transparent`: an unknown persisted value
  (e.g. a future style removed) falls back to Transparent — never crashes,
  never rewrites the fallback back to `UserDefaults`. Mirrors the existing
  `displayStyle` fallback pattern.

## Testing (swift-testing 0.12.0 API: `@Test`/`@Suite`/`#expect`/`#require`)

- **`BackgroundStyle`** — `CaseIterable.allCases.count == 3`; each case's
  `rawValue` round-trips through `init(rawValue:)`.
- **`SettingsStore`** — `backgroundStyleRaw` persists and reloads across a
  fresh `SettingsStore` instance; missing key defaults to `"transparent"`;
  an unknown persisted raw value resolves to `.transparent` via
  `backgroundStyle`.
- **`MenuBarLabelView.effectiveDark`** (pure computed property, testable
  without rendering) — `.transparent` + light `colorScheme` → `false`;
  `.transparent` + dark `colorScheme` → `true`; `.light` → `false`
  regardless of `colorScheme`; `.dark` → `true` regardless of
  `colorScheme`.
- **`LabelComposite` regression** — `.transparent` output image size is
  identical to the pre-feature baseline for a given model/icon combo (no
  existing test's expected size may change).
- **`LabelComposite` new cases** — `.light`/`.dark` output image width
  equals the `.transparent` width for the same model plus exactly
  `pillPadding * 2`; height is unchanged (still 24).
- **Manual smoke check** (owner: Ser, same pattern as prior visual-only
  features): confirm the pill renders correctly and stays legible in both
  system light and dark menu bars, across all three background styles, as
  activity text length changes (pill must grow/shrink without clipping or
  overlapping the real menu bar edge).

## Out of scope

- User-configurable background colors (no new `ColorPicker`).
- Background shapes other than a full capsule (no rect/rounded-rect
  option).
- Applying a background to the popover window.
- Any interaction with the usage-level text colors (normal/yellow/red) —
  those stay independent of background style.
- Blur/vibrancy materials (`NSVisualEffectView`-style) — plain fill only.
