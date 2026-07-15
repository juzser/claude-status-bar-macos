# CLAUDE.md

Instructions for Claude Code (or any AI coding agent) working in this repo.

## What this is

A native Swift/SwiftUI macOS menu bar app that shows Claude usage and Claude
Code activity at a glance, built pure-SwiftPM (no Xcode project).

## Architecture: 3 targets

Defined in `Package.swift`:

- **`StatusBarCore`** (library) — all business logic: account discovery,
  usage fetching/caching, session aggregation, hook event handling, settings
  persistence, and menu-bar label text/color formatting. This is the *only*
  target with tests (`Tests/StatusBarCoreTests/`, one file per source file).
- **`ClaudeStatusBar`** (executable) — the SwiftUI menu bar app. Depends on
  `StatusBarCore`. Kept as thin as possible: views read from `AppState` and
  `SettingsStore`, they don't contain logic worth unit-testing on their own.
- **`ClaudeStatusHook`** (executable) — the `claude-status-hook` binary that
  Claude Code invokes on session events. Also depends on `StatusBarCore`.

New logic goes in `StatusBarCore` with a matching test file, not in either
executable — that's what keeps almost the entire app reachable from a fast
unit test suite despite the two executables having no tests of their own.

## Build and test

CLT-only (Command Line Tools), no Xcode required, macOS 14+, Swift 6 tools
with `.v5` language mode per target.

```sh
make build   # swift build (debug)
make test    # swift test — full StatusBarCoreTests suite
make app     # dist/ClaudeStatusBar.app (release build + bundle)
make dmg     # dist/ClaudeStatusBar.dmg
```

`swift-testing` is pinned at `exact: "0.12.0"` in `Package.swift` rather than
tracking latest — this is a CLT-only environment with no Xcode to manage
toolchain/package version drift, so the pin keeps `swift test` reproducible
across machines and CI. Only the `@Test`/`@Suite`/`#expect`/`#require` API
available at that version is usable — don't reach for newer swift-testing
features (e.g. exit tests, custom traits) when writing tests here.

## Non-obvious constraints worth knowing before you touch this code

- **`LabelComposite` bakes the whole menu bar label into one `NSImage`.**
  `MenuBarExtra` flattens its `label` closure into the status button's single
  image slot plus title — only the first `Image` survives and it always
  precedes any text. A multi-view `HStack` can't express text-first ordering
  or keep the icon once the activity text is itself an image (the shimmer
  effect). `LabelComposite.image(...)` composites icon + activity text +
  usage text into one image explicitly instead of fighting that constraint.
- **`NSApp` is `nil` during `ClaudeStatusBarApp.init()`.** It's too early in
  the SwiftUI `App` lifecycle; `NSApplication.shared` creates the app object
  on first access, which is why `init()` calls
  `NSApplication.shared.setActivationPolicy(.accessory)` rather than
  `NSApp?.setActivationPolicy(...)`.
- **`AppState`'s ticker is a plain `Task` loop, not a `TimelineView`.** A
  periodic `TimelineView` inside the `MenuBarExtra` label re-anchors its
  schedule to `.now` on every label re-render, so the first scheduled entry
  is always already due — the main thread spins at 100% CPU and the status
  item never finishes appearing (observed on macOS 26). `AppState.tick`
  advances on a `Task.sleep` loop instead, throttled to 33ms (30fps) while
  activity text needs shimmer frames on the bar, or 1Hz for icon-only/compact
  styles where nothing sub-second is visible.
- **The hook binary must never fail Claude Code.** `ClaudeStatusHook`'s
  `main.swift` swallows every error into a silent `exit(0)` — the hook is
  fire-and-forget from Claude Code's perspective and must never block or
  corrupt a session.
- **OAuth tokens are read at request time only**, kept in a local variable,
  and never logged, cached, or written elsewhere (`AppState.token`). Newer
  cux versions (v0.2.11+) keep the real token only in the macOS Keychain, not
  in any slot's `oauth.json`, so `token(for:)` falls back to
  `AccountDiscovery.keychainAccessToken()` — but only when `account.isActive`,
  since cux swaps just the active slot's token into the Keychain and applying
  the fallback to inactive accounts would misattribute that token to them.
  That fallback is further gated on the account's org having no entry yet in
  cux's own usage cache (`cached == nil`) — cux rewrites the shared Keychain
  item on every `cux switch`, resetting macOS's "Always Allow" grant for it,
  so an unconditional per-poll-cycle Keychain read re-prompts the user
  constantly for no benefit once a cached snapshot already covers that org.

## Workflow

Feature branch → PR into `main` → CI (`swift test` + hook integration test,
see `.github/workflows/ci.yml`) must pass → owner review and merge. Never
push directly to `main`.

See `CONTRIBUTING.md` for the human-facing contribution guide (test
expectations, code style, where to report bugs).
