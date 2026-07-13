# Contributing

Thanks for considering a contribution to Claude Status Bar. This is a small,
personal open-source project — the process is lightweight on purpose.

## Build and test

See the [Build from source](README.md#build-from-source) section of the
README for prerequisites and the `make build` / `make test` / `make app` /
`make dmg` targets. CI runs `swift test` (same as `make test`) plus the hook
integration test (`make hook-test`) on every PR — run both locally before you
open one.

## Tests are expected

This codebase is developed test-first, and the existing suite in
`Tests/StatusBarCoreTests/` (one file per source file being tested, e.g.
`SettingsStore.swift` → `SettingsStoreTests.swift`) is the pattern to follow:

- Use [swift-testing](https://github.com/apple/swift-testing), not XCTest —
  `@Suite`/`@Test` and `#expect`/`#require`. The package pins
  `swift-testing` at `exact: "0.12.0"`, so stick to the `@Test`/`@Suite`/
  `#expect`/`#require` surface available at that version; don't reach for
  newer swift-testing API.
- New logic belongs in `StatusBarCore` (the tested library target) with a
  matching test file, not in the `ClaudeStatusBar` or `ClaudeStatusHook`
  executables — those two stay thin UI/CLI shells so almost everything is
  reachable from a unit test.
- Add a failing test for the behavior you're changing before you write the
  fix/feature, then make it pass. PRs that add behavior with no matching
  test will be asked to add one.

## Workflow

1. Fork or branch, then work on a feature branch (this repo's history is
   entirely `feat/...`/`fix/...`/`docs/...` branches merged via PR — there
   are no direct commits to `main`).
2. Open a PR into `main`. CI (`swift test` + the hook integration test) must
   pass before merge.
3. Keep PRs focused — one feature or fix per PR is easier to review than a
   bundle of unrelated changes.

## Code style

- Doc comments (`///`) explain *why*, not *what* — see `LabelComposite.swift`
  or `SettingsStore.swift` for the house style. A comment earns its place by
  recording a non-obvious constraint or a decision that isn't visible from
  reading the code (e.g. why a value is computed a particular way, a gotcha
  that was hit once and shouldn't be re-hit). Don't restate the signature in
  prose.
- Match existing naming and structure in the file you're editing rather than
  introducing a new convention.

## Reporting bugs / proposing features

Use [GitHub Issues](https://github.com/juzser/claude-status-bar-macos/issues).
For bugs, include your macOS version and, if relevant, whether you're using
[cux](https://cux.inulute.com) multi-account mode or the plain
`~/.claude/.credentials.json` path.
