# Claude Status Bar for macOS — v1 Design

**Date:** 2026-07-10
**Status:** Approved (brainstorm 2026-07-10)
**Origin:** Port of the idea behind [claude-status-bar-kde](https://github.com/vntrungld/claude-status-bar-kde)
(Plasma 6 widget). No code is reused from that repo (it has no license); this is a
clean-room reimplementation in Swift. The Clawd artwork originates from
[clawd-tank](https://github.com/marciogranzotto/clawd-tank) (MIT) and may be reused
with attribution.

## Goal

A native macOS menu bar app that shows, at a glance:

1. **Claude usage** — 5-hour and 7-day utilization percentages for the active
   Claude account, and for **all accounts managed by cux** (the operator's
   multi-account CLI, storing state under `~/.cux`) in a popover.
2. **Claude Code activity** — what Claude Code sessions are doing right now
   (idle / thinking / running a tool), via Claude Code hooks.

Differences from the KDE original (the "extra features"):

- **Multi-account**: discovers every account in `~/.cux` and shows per-account usage
  bars in the popover. The menu bar shows the *active* account only.
- **Click popover** with detailed sessions + accounts view.
- **Settings window** (display style, poll interval, thresholds, launch at login,
  hook install/remove). Designed so new options can be added without architectural
  change (all settings in `UserDefaults`).
- **Event-driven refresh**: file watching via DispatchSource/FSEvents instead of the
  KDE widget's 1-second polling timer (battery-friendly).

## Non-goals (v1)

- No notifications on threshold crossing (v2 candidate).
- No OAuth token refresh — when a token is rejected (401) the account is shown
  dimmed with a "re-login needed" badge; cux/claude own token lifecycle.
- No App Store distribution, no app sandbox.
- No Sparkle auto-update; distribution is GitHub Releases (Homebrew cask later).

## Architecture

One repo, three targets. Project is described by **XcodeGen** (`project.yml`
checked in, `.xcodeproj` generated, never committed). Build/test wrapped in a
`Makefile` (`make generate / build / test / app / dmg`). Minimum macOS 14 (Sonoma).

| Target | Kind | Purpose |
|---|---|---|
| `StatusBarCore` | library | All logic: models, path helpers, usage-response parsing, account discovery, session aggregation state machine, `settings.json` hook merge. Fully unit-tested, zero UI imports. |
| `ClaudeStatusBar` | SwiftUI app | `MenuBarExtra` + popover + Settings scene. Renders `StatusBarCore` state, owns timers/watchers. |
| `claude-status-hook` | CLI executable | Invoked by Claude Code hooks with the event name as argv[1]; reads the JSON payload from stdin; writes one session JSON file. Bundled inside the app (`Contents/MacOS/`). |

## Data flow

Two independent pipelines, mirroring the KDE design.

### Usage pipeline (multi-account)

1. **Account discovery** (`AccountProvider` protocol):
   - `CuxAccountProvider`: reads `~/.cux/state.json` (slots, emails, aliases,
     `activeSlot`) and per-account tokens from
     `~/.cux/accounts/<slot>-<email>/oauth.json`.
   - `CredentialsFileProvider` (fallback when `~/.cux` is absent): single account
     from `~/.claude/.credentials.json` (key `claudeAiOauth.accessToken`).
   - Neither file's contents are ever logged or written anywhere else.
2. **Polling** (`UsageService`): for each discovered account, `GET
   https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>`,
   every 5 minutes (configurable 1/5/15). Requests run per-account and
   independently; one failure never blocks the others.
3. **Model**: 5-hour and 7-day utilization percent + reset timestamps, per account
   (field names per the KDE reference implementation; the parser is written
   tolerant to unknown/missing fields and verified against the live response
   during implementation).
4. Last good result per account is kept in memory and cached on disk
   (`~/Library/Application Support/ClaudeStatusBar/usage-cache.json`) so a restart
   starts warm.

### Activity pipeline (Claude Code hooks)

1. **Install** (opt-in, from Settings or first-run prompt): merge hook entries into
   `~/.claude/settings.json` for events `SessionStart`, `UserPromptSubmit`,
   `PreToolUse`, `PostToolUse`, `Stop`, `Notification`, each invoking the bundled
   `claude-status-hook <EventName>`. Merge is idempotent, preserves existing hooks,
   validates JSON, and writes a timestamped backup first. Uninstall removes exactly
   the entries it added.
2. **Write**: `claude-status-hook` derives
   `{session_id, state, label, cwd, started_at, updated_at}` from the event payload
   and atomically writes (temp file + `rename`)
   `~/Library/Application Support/ClaudeStatusBar/sessions/<session_id>.json`.
   Any error is swallowed; the tool always exits 0 so Claude Code is never blocked.
3. **Read**: the app watches the sessions directory (DispatchSource/FSEvents) and
   re-aggregates on change. Aggregation rules (in `StatusBarCore`):
   - Session state machine: `idle` → `thinking` (UserPromptSubmit) → `tool`
     (PreToolUse, with a human label like "Editing"/"Running"/"Browsing") →
     back to `idle` (Stop).
   - Sessions with `updated_at` older than **15 minutes** are treated as stale and
     excluded. Files are filtered, not deleted.
   - Display state = the "busiest" live session (tool > thinking > idle).

## UI

### Menu bar (compact)

- **Clawd icon**, animated per aggregate state: idle / thinking / tool-running.
- Optional text next to the icon (each part toggleable in Settings):
  - Active tool label + elapsed timer while a session is busy. While thinking,
    rotate through the KDE original's playful verb set ("Brewing…", "Pondering…",
    ~28 variants, no immediate repeats).
  - Usage pair for the **active account**: `5h 70% · 7d 29%`, each with a colored
    dot — green < 50%, yellow 50–80%, red ≥ 80% (thresholds configurable).

### Popover (left-click)

- **Sessions** section: one row per live session — project name (last path
  component of `cwd`), state label, elapsed time.
- **Accounts** section: one block per visible account — alias + email, 5h and 7d
  horizontal bars with percent and time-until-reset. Active account highlighted.
  Stale/errored data rendered at 50% opacity; 401 shows a "re-login needed" badge.
- Footer: `Refresh` · `Settings…` · `Quit`.

### Settings window

- **General**: launch at login (SMAppService) · show usage on menu bar · display
  style (icon only / icon + % / full) · usage poll interval (1/5/15 min).
- **Thresholds**: yellow/red boundaries (defaults 50/80).
- **Accounts**: auto-discovered list; per-account show/hide in popover.
- **Claude Code**: hook status (installed / not installed) + Install / Remove.

## Error handling

- `claude-status-hook`: never throws past `main`, always exit 0; malformed stdin
  is ignored; writes are atomic.
- Usage fetch: per-account isolation; 401 → dimmed + re-login badge; 429 →
  exponential backoff for that account; network failure → keep last value, dimmed.
  Malformed JSON never crashes — parse failures degrade to "no data".
- Missing `~/.cux` → fallback single-account mode; missing both sources → popover
  shows an empty state explaining no Claude account was found.
- `settings.json` hook install: backup → merge → validate → write; abort (and
  surface an error in Settings) rather than write invalid JSON.
- The app is **not sandboxed** (it must read `~/.claude` and `~/.cux`).

## Packaging & distribution

- `xcodegen` + `xcodebuild`, driven by `Makefile`; CI on GitHub Actions (macOS
  runner) runs `xcodebuild test` per PR.
- v1 releases: DMG on GitHub Releases, ad-hoc signed. Notarization + Homebrew cask
  once stable.
- License: **MIT**. Clawd artwork attributed to clawd-tank (MIT).

## Testing

- **Unit (Swift Testing, on `StatusBarCore`)**: usage-response parsing (fixtures,
  including malformed/partial); account discovery against a fixture `~/.cux` tree
  and a fixture `.credentials.json`; session aggregation state machine incl. stale
  filtering and busiest-session selection; hook payload → session-file mapping;
  `settings.json` merge (fresh install, re-install idempotency, uninstall,
  preserving foreign hooks).
- **Integration**: run the built `claude-status-hook` binary with fixture stdin
  payloads; assert the session file content and exit code 0.
- **Manual smoke**: menu bar rendering, popover, settings persistence, live hook
  round-trip with a real Claude Code session.

## v2 candidates (out of scope)

Threshold notifications; 5h-block-reset notification; Sparkle auto-update;
Homebrew cask; per-account cost/token stats (ccusage-style); showing cux slot
switch actions in the popover.
