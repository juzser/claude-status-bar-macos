# Claude Status Bar for macOS

[![CI](https://github.com/juzser/claude-status-bar-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/juzser/claude-status-bar-macos/actions/workflows/ci.yml)

Native macOS menu bar app showing Claude usage and Claude Code activity at a
glance. A clean-room Swift port of the idea behind
[claude-status-bar-kde](https://github.com/vntrungld/claude-status-bar-kde),
with multi-account support.

## Features

- **Usage at a glance** — 5-hour and 7-day utilization for the active Claude
  account in the menu bar, color-coded (green / yellow ≥50% / red ≥80%,
  configurable).
- **Multi-account** — discovers every account managed by
  [cux](https://cux.inulute.com) under `~/.cux` (falls back to
  `~/.claude/.credentials.json`); per-account usage bars in the popover.
- **Claude Code activity** — Clawd shows what your sessions are doing right
  now (thinking, editing, running…), with playful verbs and elapsed timers,
  driven by Claude Code hooks + file watching (no polling loop).
- **Settings** — display style, poll interval, thresholds, per-account
  visibility, launch at login, hook install/remove.

## Install

Download `ClaudeStatusBar.dmg` from Releases, drag to Applications, launch.
The app lives in the menu bar only (no Dock icon).

The app is ad-hoc signed, so macOS quarantines the downloaded copy and the
first launch is refused ("cannot verify" / "damaged"). Right-click the app in
Applications and choose **Open** (twice if needed), or clear the quarantine
flag directly:

```sh
xattr -d com.apple.quarantine /Applications/ClaudeStatusBar.app
```

To enable activity tracking: Settings → Claude Code → Install. This adds
hook entries to `~/.claude/settings.json` (a timestamped backup is written
first; Remove deletes exactly what Install added).

## Build from source

Requires macOS 14+ and Command Line Tools (no Xcode needed).

```sh
make build   # debug build
make test    # unit + integration tests
make app     # dist/ClaudeStatusBar.app
make dmg     # dist/ClaudeStatusBar.dmg
```

## Security notes

- OAuth tokens are read from disk only at request time and sent only to
  `api.anthropic.com`. They are never logged, cached, or written elsewhere.
- The app is not sandboxed (it must read `~/.claude` and `~/.cux`).
- The hook binary always exits 0 and prints nothing, so it can never block
  or corrupt a Claude Code session.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the
build/test/PR workflow, and [CLAUDE.md](CLAUDE.md) if you're using Claude
Code (or another AI coding agent) to work in this repo.

## License

MIT. Clawd artwork from
[clawd-tank](https://github.com/marciogranzotto/clawd-tank) (MIT) — see
`LICENSE.clawd-tank`.
