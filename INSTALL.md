# Installation Guide

Step-by-step instructions for getting Claude Status Bar running on your Mac,
enabling Claude Code activity tracking, and (optionally) wiring up multi-account
usage via [cux](https://cux.inulute.com). For the short version, see the
[Install](README.md#install) section of the README.

## 1. Prerequisites

- **macOS 14 (Sonoma) or later.** The app's `Info.plist` sets
  `LSMinimumSystemVersion` to `14.0`.
- **[Claude Code](https://docs.claude.com/en/docs/claude-code)** installed, if
  you want the menu bar to show live session activity (step 4). The app also
  works purely as a usage monitor without it.
- **Command Line Tools only** if you're building from source — no full Xcode
  install is required:

  ```sh
  xcode-select --install
  ```

## 2. Get the app

### Path A — download a release (when one is available)

Check the [Releases page](https://github.com/juzser/claude-status-bar-macos/releases)
for a `ClaudeStatusBar.dmg` asset. At the time of writing this project has no
published releases yet, so build from source (Path B) is the primary
installation path until the first release ships.

Once a release exists:

1. Download `ClaudeStatusBar.dmg` from Releases.
2. Open the disk image and drag `ClaudeStatusBar.app` to `/Applications`.
3. Continue at [step 3, First launch](#3-first-launch--gatekeeper).

### Path B — build from source

1. Clone the repo:

   ```sh
   git clone https://github.com/juzser/claude-status-bar-macos.git
   cd claude-status-bar-macos
   ```

2. Build the app bundle:

   ```sh
   make app
   ```

   This runs `swift build -c release` and assembles
   `dist/ClaudeStatusBar.app` (see `scripts/make-app.sh`). Use `make dmg`
   instead if you also want a `dist/ClaudeStatusBar.dmg` disk image.

3. Copy the app to your Applications folder:

   ```sh
   cp -R dist/ClaudeStatusBar.app /Applications/
   ```

## 3. First launch / Gatekeeper

The app is ad-hoc signed (`codesign --sign -`, no Apple Developer ID), so
macOS quarantines it and Gatekeeper refuses the first launch with a
"cannot verify" or "damaged" warning — this is expected for both Path A and
Path B installs. Do one of the following:

- Right-click `ClaudeStatusBar.app` in `/Applications` and choose **Open**
  (you may need to repeat this once), or
- Clear the quarantine flag directly:

  ```sh
  xattr -d com.apple.quarantine /Applications/ClaudeStatusBar.app
  ```

The app is menu-bar-only (`LSUIElement` is set) — it never shows a Dock icon
or an app switcher entry. Look for its icon in the menu bar after launch.

## 4. Enable activity tracking

To have the menu bar reflect what your Claude Code sessions are doing
(thinking, editing, running…), open the app's settings and go to the
**Claude Code** tab, then click **Install**.

What this does, exactly:

- Writes hook entries for the `SessionStart`, `UserPromptSubmit`,
  `PreToolUse`, `PostToolUse`, `Stop`, and `Notification` events into
  `~/.claude/settings.json`, pointing at the `claude-status-hook` binary
  bundled next to the app.
- Writes a timestamped backup of your existing `~/.claude/settings.json`
  first (e.g. `settings.json.claude-status-bar-backup-<ISO8601 timestamp>`,
  in the same directory), before making any change.
- Is idempotent — running Install again replaces any prior entry of ours
  rather than duplicating it, and never touches hook entries added by
  something else.

Clicking **Remove** deletes exactly the hook entries Install added and
leaves the rest of `~/.claude/settings.json` untouched. The status line in
the same tab reads "Installed" (or not) based on whether the hook is
currently present.

## 5. Multi-account usage (optional)

If you manage more than one Claude account, install
[cux](https://cux.inulute.com) — the app reads account slots straight from
`~/.cux` (falling back to the single account in
`~/.claude/.credentials.json` when cux isn't managing any accounts).

1. Install cux and add your accounts to it, following cux's own setup
   instructions at https://cux.inulute.com.
2. Relaunch (or reopen the popover in) Claude Status Bar. Every slot cux
   manages under `~/.cux` shows up as its own row in the popover, each with
   its own 5-hour and 7-day usage bars; the currently active slot is marked
   **active**.
3. To make a different slot the active account, click its **Switch** button.
   This runs `cux switch <slot>` in the background.
4. If a row shows a **re-login needed** badge (its token was rejected),
   click **Log in** next to it:
   - For a cux-managed slot, this runs `cux switch <slot> && cux /login` —
     it makes that slot active, then runs Claude Code's login flow under the
     cux wrapper so the fresh token is synced back into the slot.
   - For the plain `~/.claude` account (no cux slot), it runs
     `claude /login` directly.

   Either command opens in a terminal window so you can complete the OAuth
   flow interactively.

Without cux installed, the app just shows the single account from
`~/.claude/.credentials.json`, if present.

## 6. Verify it works

After enabling hooks (step 4) and launching a Claude Code session in a
terminal, the menu bar label should show, from left to right (depending on
your chosen display style in Settings): the current activity text (e.g.
"Editing… · 12s"), the Clawd icon reflecting that activity, and your active
account's 5-hour usage percentage. Click the menu bar item to open the
popover for the full picture — per-account 5h/7d usage bars and the list of
active Claude Code sessions.

If Claude Code isn't running anything, Clawd sits idle and only the usage
percentage (if enabled) is shown.

## 7. Uninstall

1. Open the app's settings, go to the **Claude Code** tab, and click
   **Remove** to strip the hook entries from `~/.claude/settings.json`
   (see step 4 for exactly what this undoes).
2. Quit Claude Status Bar: click the menu bar icon to open the popover, then
   click **Quit**.
3. Delete the app:

   ```sh
   rm -rf /Applications/ClaudeStatusBar.app
   ```

cux, if you installed it for multi-account usage, is a separate tool and is
not affected by uninstalling Claude Status Bar.
