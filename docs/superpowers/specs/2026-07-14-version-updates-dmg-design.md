# Version Display, Check for Updates, and DMG Applications Shortcut — Design

**Date:** 2026-07-14
**Status:** Approved pending user spec review
**Repo:** claude-status-bar-macos (base: main @ a2fc31a)

## Goal

Two independent, small pieces of work, bundled into one spec since both are
small:

1. Show the app's version somewhere in Settings, and let the user check
   GitHub for a newer release — automatically once per launch/day, and
   on-demand via a button.
2. When building the DMG (`make dmg`), stage an `/Applications` symlink
   alongside `ClaudeStatusBar.app` so users can drag-and-drop install,
   matching the pattern used by most macOS app DMGs.

## Background

- The only existing version string is `VERSION="${VERSION:-0.1.2}"` in
  `scripts/make-app.sh:11`, used solely to populate
  `CFBundleShortVersionString`/`CFBundleVersion` in the `.app`'s
  `Info.plist`. No Swift code reads it today.
- Releases are already published on GitHub under a `vX.Y.Z` tag/title
  convention (`v0.1.0`, `v0.1.1`, `v0.1.2` at time of writing), so the
  GitHub Releases API is a ready-made source of truth for "is there a newer
  version" — no custom release-manifest infrastructure needed.
- `Makefile`'s `dmg` target currently does
  `hdiutil create -srcfolder dist/ClaudeStatusBar.app ...` — no
  `/Applications` symlink is staged.
- The app is self-signed and not notarized (see `README.md` "First
  launch / Gatekeeper" section), so an in-app auto-download-and-replace
  flow is out of scope — updates stay a manual, user-initiated download,
  consistent with today's install instructions.

## Decisions (from brainstorming)

1. **One combined spec** for both pieces, since each is small; the
   implementation plan can still task them separately.
2. **Version + update-check UI lives in a new "About" tab** in
   `SettingsView.swift`, alongside the existing General / Thresholds /
   Accounts / Claude Code tabs.
3. **Update checks run both automatically and manually:** once shortly
   after launch, then at most once per 24h while the app keeps running, plus
   an on-demand "Check for Updates" button in the About tab. No persisted
   "last checked" timestamp across launches — GitHub's unauthenticated rate
   limit (60 requests/hour per IP) comfortably covers a once-a-day
   background check plus occasional manual clicks.
4. **On finding a newer version, the app notifies and links out — it does
   not download or install anything.** The About tab shows "Update
   available: vX.Y.Z" with a button that opens the GitHub release page
   (`NSWorkspace.shared.open(url)`) for the existing manual
   download-and-drag-to-Applications flow. No in-app download, no
   self-replacement — the app isn't notarized, so there's no safe way to
   silently swap the running bundle.
5. **No menu-bar icon badge.** The update indicator appears in the About
   tab and in the popover (a small line near the account/session info) —
   not composited into the menu-bar `NSImage` itself. `LabelComposite`
   bakes icon + activity text + usage text into one image explicitly
   (`CLAUDE.md`'s documented constraint); threading a rarely-changing,
   low-urgency badge through that already-delicate compositing path isn't
   worth the risk for this feature.
6. **DMG gets a plain functional `/Applications` symlink, not a styled
   installer window.** No background image, no AppleScript-driven Finder
   icon positioning — just stage the `.app` and the symlink side by side
   before calling `hdiutil create`.

## Architecture

### Version + Check for Updates

**New files:**

- `Sources/StatusBarCore/Updates/ReleaseInfo.swift` — the `ReleaseInfo`
  model (`tagName`, `htmlURL`) and JSON parsing, mirroring
  `Usage/UsageModels.swift`'s `UsageSnapshot.parse(_:fetchedAt:)` shape.
- `Sources/StatusBarCore/Updates/GitHubReleaseClient.swift` — a
  `ReleaseFetching` protocol plus `GitHubReleaseClient: ReleaseFetching`,
  mirroring `Usage/UsageClient.swift`'s `UsageFetching`/`UsageClient` split
  (injectable `URLSession`, `GET
  https://api.github.com/repos/juzser/claude-status-bar-macos/releases/latest`).
- `Sources/StatusBarCore/Updates/UpdateChecker.swift` — an `actor`
  mirroring `Usage/CuxRefresher.swift`'s shape: injectable `fetch` closure,
  `minInterval: TimeInterval = 86400` (24h), a `lastAttempt: Date?`, and
  `checkIfNeeded(currentVersion: String, now: Date = Date()) async ->
  ReleaseInfo?` that returns the latest release only when
  `isNewer(latestTag:currentVersion:)` is true, else `nil`. A separate pure
  static function `isNewer(latestTag: String, currentVersion: String) ->
  Bool` strips a leading `"v"` and compares `X.Y.Z` components numerically;
  if either side fails to parse as three integers, it returns `false` (not
  newer) so a malformed tag can't crash the comparison or trigger a false
  "update available."
- `Sources/ClaudeStatusBar/AppVersion.swift` — reads
  `Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String`,
  falling back to `"dev"` when absent (unbundled `swift run`/debug
  context, which has no `Info.plist`).

**Modified files:**

- `Sources/ClaudeStatusBar/AppState.swift` — owns one `UpdateChecker`
  instance and one `@Published var updateAvailable: ReleaseInfo?`. On
  `init`, kicks off a `Task` shaped like the existing
  `pollTask`/`reaggregateTask` loops: call `checkIfNeeded` immediately (no
  artificial startup delay), then loop `Task.sleep(for: .seconds(86400))`
  calling it again. Exposes a `func checkForUpdatesNow() async` for the
  manual button. `checkIfNeeded`'s own `minInterval` gate would block a
  manual click made seconds after the automatic check, so
  `checkForUpdatesNow()` calls a separate
  `UpdateChecker.checkNow(currentVersion:) async -> ReleaseInfo?` that does
  the fetch + `isNewer` comparison with no rate limiting, and also resets
  `lastAttempt` to `now` so the following automatic loop iteration doesn't
  immediately re-fire.
- `Sources/ClaudeStatusBar/SettingsView.swift` — new `AboutTab` view
  (added to the `TabView`): shows `AppVersion.current`, a "Check for
  Updates" button calling `appState.checkForUpdatesNow()`, and status text
  — "You're up to date" / "Update available: vX.Y.Z" with a "View Release"
  button opening `updateAvailable.htmlURL` via
  `NSWorkspace.shared.open(_:)`.
- `Sources/ClaudeStatusBar/PopoverView.swift` — when
  `appState.updateAvailable != nil`, shows one small line ("Update
  available: vX.Y.Z") near the top, no icon compositing involved.

**Error handling:** network failures (offline, GitHub API down, rate
limited) are swallowed the same way `CuxRefresher.refreshIfNeeded` swallows
CLI failures — `checkIfNeeded`/`checkNow` simply return `nil`, leaving
`updateAvailable` unchanged. Update checks are a nice-to-have background
signal, never a user-facing error state.

**Testing (`Tests/StatusBarCoreTests/`):**

- `UpdateCheckerTests.swift` — mirrors `CuxRefresherTests.swift`'s shape:
  - `isNewer` pure-function cases: `"v0.1.3"` vs `"0.1.2"` → true;
    `"v0.1.2"` vs `"0.1.2"` → false; `"v0.1.1"` vs `"0.1.2"` → false;
    malformed tag (`"nightly"`) vs `"0.1.2"` → false.
  - `checkIfNeeded` rate-limiting: same `now:`-parameterized pattern as
    `CuxRefresherTests.rateLimits()` — first call with a stubbed `fetch`
    closure returning a newer release fires it; a second call
    `minInterval - 1` seconds later does not re-fetch; a call
    `minInterval + 1` seconds later does.
  - `checkIfNeeded` returns `nil` when the stubbed fetch throws.
  - `checkNow` bypasses the interval gate even immediately after a prior
    call.
- No test hits the real network — `GitHubReleaseClient` is only
  constructed in `AppState`; `UpdateCheckerTests` inject a stub `fetch`
  closure directly into `UpdateChecker`, same as `CuxRefresherTests`
  injects a stub `run` closure into `CuxRefresher`.

### DMG Applications shortcut

**New file:** `scripts/make-dmg.sh` — extracted from the `Makefile`'s
inline `dmg` recipe, mirroring `make-app.sh`'s `set -euo pipefail` /
`cd "$(dirname "$0")/.."` header:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R dist/ClaudeStatusBar.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f dist/ClaudeStatusBar.dmg
hdiutil create -volname ClaudeStatusBar -srcfolder "$STAGING" \
  -ov -format UDZO dist/ClaudeStatusBar.dmg
```

**Modified file:** `Makefile` — the `dmg` target becomes:

```makefile
dmg: app
	bash scripts/make-dmg.sh
```

No change to `make-app.sh`'s signing/notarization behavior — this only
changes what gets staged into the `.dmg`.

## Out of scope

- In-app auto-download or self-replacing update installation.
- Persisting "last update check" across app restarts.
- A menu-bar icon badge for available updates.
- A styled/branded DMG installer window (background image, fixed icon
  positions).
- Any change to how `VERSION` is set for the `.app` bundle itself
  (`scripts/make-app.sh`'s `VERSION="${VERSION:-0.1.2}"` default is bumped
  manually per release today, and stays that way).
