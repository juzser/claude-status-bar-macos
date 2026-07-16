# Native Account Switching (Replace cux)

**Date:** 2026-07-16
**Status:** Approved (design), pending spec review
**Repo:** claude-status-bar-macos @ 7461b3b (main)

## Goal

Replace `cux switch` — the one remaining cux dependency (usage fetching is
already cux-independent) — with a native Swift implementation that adds,
switches, and re-logs-in Claude accounts directly against the macOS
Keychain, without shelling out to the `cux` binary at all.

## Background

cux (`github.com/inulute/cux`, GPL-3.0) currently owns three things this app
relies on:

1. **Account discovery** — reading `~/.cux/state.json` for the list of known
   accounts and which slot is active.
2. **Credential backup** — a per-account stash in the Keychain (service
   `"cux-backup"`) holding each account's OAuth credentials.
3. **Switching** — `cux switch <slot>`, which copies a backed-up account's
   credentials into the "live" Keychain item (service
   `"Claude Code-credentials"`, generic-password) that the real `claude` CLI
   reads, after first backing up whatever was live.

`CuxAccountSwitcher` (`Sources/StatusBarCore/Accounts/CuxAccountSwitcher.swift`)
is today's integration point: an actor that shells out to `cux switch
<slot>` and is called from `AppState.swift` (`cuxAccountSwitcher.switchTo
(slot:)`). `ReloginCommand.command(for:)` branches on `account.slot != nil`
to build either `"cux switch \(slot) && cux /login"` or bare `"claude
/login"`, handed to `TerminalLauncher.run(_:)`, which writes the command to
a `.command` file and opens it via `NSWorkspace.shared.open` — fire-and-
forget, with no signal back to the app when the shell script finishes.

A prior investigation (this session, predating this spec) identified a
likely root cause for an intermittent Keychain-permission-prompt bug:
`security add-generic-password -U`, which cux uses to write the live item,
resets that item's trusted-application ACL on every write, dropping any
prior "Always Allow" grant the user had given. A native writer can instead
set an explicit `SecAccess`/`SecTrustedApplication` ACL that includes both
`claude` and this app, so switches don't regress Keychain trust.

## Decisions (from brainstorming)

1. **Full independence, not a thin swap.** The app gets its own account list
   (`NativeAccountStore`) and its own credential backups
   (`AccountCredentialVault`), rather than continuing to read
   `~/.cux/state.json` for discovery while only replacing the switch
   subprocess call. This is required because "add an account" (decision 2)
   needs an app-owned place to capture a freshly-logged-in account into —
   there is no such place if discovery still belongs to cux.
2. **Adding an account uses capture-after-login, not an interactive form.**
   The user logs in via the real `claude /login` flow (browser hand-off);
   the app detects the resulting change to the live Keychain item and
   captures it as a new (or refreshed) account. There is no native OAuth
   client in this app — captured credentials are exactly what `claude
   /login` produced.
3. **Switching uses the Keychain Services API directly** (`SecItemCopyMatching`
   / `SecItemAdd` / `SecItemUpdate`, wrapped for testability), not shell-outs
   to `security`, mirroring cux's `SwitchTo` staging order but executed
   in-process.
4. **Existing cux-managed accounts are migrated in on first run** — a
   one-time import of `~/.cux/state.json` plus cux's `"cux-backup"` Keychain
   service into the native store, so current multi-account users don't lose
   their account list when this ships.
5. **The `Account` struct and all existing UI (`AccountsSection`,
   `AccountRow`) are unchanged.** New components produce the same `Account`
   value type consumed today; only what's underneath changes.

## Architecture

### Components (all in `Sources/StatusBarCore/Accounts/`)

| Component | Responsibility |
|---|---|
| `NativeAccountStore` | Persists the app's own account list (id, alias, email, org uuid, managed index) as JSON under `AppPaths().root`. Replaces `~/.cux/state.json` as the source of truth for discovery. Assigns each tracked account a stable integer **managed index**, reusing `Account.slot`'s existing role (see "Reusing `Account.slot`" below) rather than adding a new field. |
| `AccountCredentialVault` | Reads/writes each account's backed-up OAuth credentials to/from a dedicated Keychain service (`"ClaudeStatusBar-backup"`), keyed by account id. Replaces cux's `"cux-backup"` service. |
| `LiveCredentialWriter` | Reads/writes the live Keychain item (service `"Claude Code-credentials"`) that `claude` itself reads, via `SecItemCopyMatching`/`SecItemAdd`/`SecItemUpdate`, and sets an explicit trusted-application ACL (`claude` + this app) on write. |
| `NativeAccountSwitcher` | Orchestrates a switch: stages backup-target-read → backup-current-live → write-target-live → write-target-oauthAccount-field, matching cux's `SwitchTo` order, with rollback on any failure (see Error Handling). Actor, same call shape as today's `CuxAccountSwitcher.switchTo(slot:)` so `AppState.swift`'s call site changes minimally. |
| `AccountCapture` | Drift-detection: compares the live Keychain item's org uuid against the native store on popover-open and on a ~60s background poll. Three outcomes: no change (no-op), matches a known account (refresh its cached credentials/backup), matches no known account (create a new `Account` entry + back it up). |

### Reusing `Account.slot`

Decision 5 keeps the `Account` struct unchanged, but two existing behaviors
key off `account.slot != nil`: `AccountRow`'s "Switch" button visibility, and
`ReloginCommand.command(for:)`'s branch between a managed relogin and a bare
one. Both need to keep working for native accounts without a struct change.

`NativeAccountStore` resolves this by populating `slot` with its own
**managed index** — a stable integer it assigns each account it tracks
(starting from cux's own slot numbers for migrated accounts, and continuing
the sequence for newly captured ones). `slot` stops meaning "cux slot
number" and starts meaning "this account is under this app's management,
with an app-internal index" — every native-tracked account has one; only
an account this app has never captured (the pre-first-run bootstrap case,
or a fresh install with a single account not yet captured) has
`slot == nil`. This keeps both the Switch button and `ReloginCommand`'s
branch condition (`account.slot != nil`) working unmodified.

### Data flow

**Add account:** User clicks "Add Account" in `AccountsSection` →
`TerminalLauncher.run("claude /login")` opens a `.command` file in Terminal
→ user completes the browser OAuth hand-off → `TerminalLauncher` has no
completion signal, so the app does not know when (or whether) this
finished. Instead, `AccountCapture` runs on two triggers — popover-open and
a ~60s background timer — and reads the live Keychain item's org uuid each
time. If it differs from what was live at the last check and doesn't match
a known account, `AccountCapture` creates a new `Account`, stores it in
`NativeAccountStore`, and backs up its credentials via
`AccountCredentialVault`. If it matches a known (but stale) account, it
refreshes that account's backup instead. This asymmetry (poll instead of
callback) is a direct consequence of `TerminalLauncher` being fire-and-forget
(`Sources/ClaudeStatusBar/TerminalLauncher.swift`) — there is no
Automation/AppleEvents grant to add a real completion signal without a much
larger scope increase.

**Switch account:** `AccountsSection`'s existing "Switch" button →
`AppState` calls `NativeAccountSwitcher.switchTo(account:)` (replacing
`cuxAccountSwitcher.switchTo(slot:)`) → staged write as described above →
on success, `NativeAccountStore` marks the new account active and the old
one inactive, matching the visible behavior of today's `cux switch`.

**Re-login (expired/invalid credentials):** `ReloginCommand.command(for:)`
keeps its existing two-way branch (`account.slot != nil` → managed relogin;
else → bare `claude /login`), but the managed branch's *implementation*
changes: today it returns `"cux switch \(slot) && cux /login"`; after this
change, `slot != nil` means "native-tracked" (see "Reusing `Account.slot`"
above), so `AppState` first switches that account to live in-process
(`NativeAccountSwitcher.switchTo(account:)`, called before building the
command) and `ReloginCommand` then returns the same bare `"claude /login"`
string the untracked branch already used — so the browser flow
re-authenticates *this* account's live session rather than whichever
account happened to be live before. `AccountCapture`'s drift detection then
picks up the refreshed credentials exactly as in the add-account flow. The
old cux-shell-out string is deleted along with `CuxAccountSwitcher` itself
(see Modified files) — there is no longer a case that shells out to `cux`.

**First-run migration:** On `NativeAccountStore`'s first load, its own state
file's mere existence on disk is the migration marker — if the file exists
(even listing zero accounts), migration already ran and is skipped. Only
when the file is absent does `CuxStateImporter` check for
`~/.cux/state.json`; if present, it reads each cux-managed account and
imports it (account metadata from `state.json`, credentials from cux's
`"cux-backup"` Keychain service), then `NativeAccountStore` writes its state
file — present from then on — before returning control either way (imported
accounts, or empty if cux had none / wasn't installed). Accounts cux
doesn't have a backup for (should that ever happen) are imported with
metadata only and flagged `needsRelogin` — the same state the UI already
renders today for any account whose credentials are missing.

### New files

- `Sources/StatusBarCore/Accounts/NativeAccountStore.swift`
- `Sources/StatusBarCore/Accounts/AccountCredentialVault.swift`
- `Sources/StatusBarCore/Accounts/LiveCredentialWriter.swift`
- `Sources/StatusBarCore/Accounts/NativeAccountSwitcher.swift`
- `Sources/StatusBarCore/Accounts/AccountCapture.swift`
- `Sources/StatusBarCore/Accounts/CuxStateImporter.swift` (first-run
  migration, kept separate from `NativeAccountStore` so the one-time import
  logic can be tested and later deleted independently of the store itself)

### Modified files

- `Sources/ClaudeStatusBar/AppState.swift` — replace
  `cuxAccountSwitcher.switchTo(slot:)` (line 191) with
  `nativeAccountSwitcher.switchTo(account:)`; replace the
  `CuxAccountSwitcher()` property (line 35) with `NativeAccountSwitcher()`;
  add an `AccountCapture` instance driven from the existing popover-open
  hook and ticker loop (`AppState.tick`, already running at 1Hz/30fps per
  CLAUDE.md — the ~60s poll rides this existing loop rather than adding a
  second timer).
- `Sources/StatusBarCore/Accounts/ReloginCommand.swift` — keep the existing
  two-way branch and signature (`command(for account: Account) -> String`),
  change only the `slot != nil` case's returned string from
  `"cux switch \(slot) && cux /login"` to bare `"claude /login"` (see
  "Reusing `Account.slot`" and the re-login data-flow paragraph above). The
  in-process live-switch call happens in `AppState` before invoking
  `ReloginCommand`, not inside `ReloginCommand` itself, so `ReloginCommand`
  stays a pure string-builder with no async/Keychain dependency (matching
  its current form).
- `Sources/ClaudeStatusBar/AccountsSection.swift` — add an "Add Account"
  button (calls `TerminalLauncher.run("claude /login")` directly, no new
  `StatusBarCore` API needed since capture is drift-detected, not
  triggered).
- `Sources/StatusBarCore/Accounts/CuxAccountSwitcher.swift` — deleted once
  `NativeAccountSwitcher` fully replaces it (no remaining callers).
  `CuxAvailability`-gated messaging in `AccountsSection` ("log in with cux
  or Claude Code") is simplified since native accounts are now always
  available regardless of whether cux is installed.

## Error handling & rollback

**Switch (`NativeAccountSwitcher`):** fail-safe-first ordering — live
Keychain state is never touched until both backups (target account's
credentials read from the vault, current live credentials backed up to the
vault under the outgoing account's id) succeed. If either backup step
fails, the switch aborts before any live write and reports failure through
today's same `switchFailedAccountId` UI slot in `AccountsSection`, with its
text changed from "Switch failed — is cux installed and working?" to
"Switch failed — check native-switch.log" (cux is no longer in the failure
path, so the message should no longer name it). If the live write itself
fails partway (credentials written but the oauthAccount field update fails,
or vice versa), `NativeAccountSwitcher` re-writes the just-backed-up
outgoing credentials back to live before returning failure — mirroring
cux's own rollback behavior in `SwitchTo`. Switching to the account that is
already active is a harmless no-op: `NativeAccountSwitcher` short-circuits
and returns success without touching the Keychain, since target and
current would be identical.

**Capture (`AccountCapture`):** failures (Keychain read errors, a
malformed/missing org uuid) are logged and skipped silently — this is a
background heuristic, not a user-initiated action, so there's no
"operation failed" surface to show. It simply tries again on the next
trigger (popover-open or next ~60s tick).

**Diagnostics:** a new `native-switch.log` under `AppPaths().root`, written
by `NativeAccountSwitcher` on every switch attempt (success or failure),
mirroring the existing `cux-switch.log` / `token-resolution.log`
conventions (`CuxAccountSwitcher.invoke`,
`TokenResolutionDiagnostics.write`) — same one-entry-overwrite-or-append
style as those, never including token values.

**Migration (`CuxStateImporter`):** if `~/.cux/state.json` is present but
malformed, or cux's backup Keychain item is missing/unreadable for a given
account, that account is imported with metadata only and marked
`needsRelogin` (the existing UI path for missing credentials) rather than
failing the whole import. One unreadable account must not block importing
the rest.

## Security considerations

CLAUDE.md's existing rule — "OAuth tokens are read at request time only...
and never logged, cached, or written elsewhere" — was written for the
read-only usage-fetching path (`AppState.token`), where the token lives
only in a local variable. This feature is new territory: it persists every
known account's credentials in a vault so they can be swapped back onto the
live item later. That trade-off is deliberate, not accidental, and is
scoped as follows:

- **Storage tier is unchanged.** Vault entries live in the macOS Keychain,
  the same trust tier the official `claude` CLI and cux already use for
  this exact data — this feature does not introduce a new, weaker storage
  location.
- **Tighter ACL than the item it replaces.** The live item currently ends
  up with a dual-trust ACL (`claude` and whichever tool last wrote it,
  currently cux). Vault entries get an app-only ACL — only this app's
  binary can read them — since nothing else needs to read a backup, only
  the live item.
- **Explicit trade-off, stated plainly:** after this ships, this app
  persistently holds every configured account's credentials, not just the
  currently-active one (which is all cux's live item ever exposes to
  processes other than cux itself). A compromise of this app's Keychain
  access now yields all accounts, not one.
- **Known limitation:** setting a trusted-application ACL entry for `claude`
  itself requires resolving its binary path, and that resolution may not be
  reliable across every install method (Homebrew, npm-global, manual). Where
  it can't be resolved, the ACL falls back to including only this app,
  meaning a fresh "Always Allow" prompt would still be needed the first time
  `claude` itself is the one reading the item.
- **Threat model bounds:** this design defends against Keychain-prompt
  friction and cux-specific credential duplication. It explicitly does not
  defend against a compromised account, a rooted/malware-infected machine,
  or a keychain the user has left unlocked — the same bounds cux and the
  official CLI already operate within.

## Testing (`Tests/StatusBarCoreTests/`)

One test file per new source file, following the existing convention (e.g.
`TokenResolutionTests.swift` alongside `TokenResolution`). Every
Keychain/filesystem touchpoint is behind an injectable closure — no test
touches the real Keychain or a real `~/.cux/state.json`, matching the
pattern already used by `TokenResolution.resolve(account:cached:oauthData:
keychainAccessToken:)` and `CuxAccountSwitcher`'s injectable `run` closure.

- `NativeAccountStoreTests` — load/save round-trip against an injected file
  URL; first-run-with-no-file behavior.
- `AccountCredentialVaultTests` — read/write against injected
  Keychain-read/write closures (no `SecItemCopyMatching` call in tests).
- `LiveCredentialWriterTests` — read/write against injected closures;
  verifies the ACL-setting call is made with both trusted applications when
  both paths resolve, and with just this app's when `claude`'s path doesn't
  resolve.
- `NativeAccountSwitcherTests` — the highest-value surface. Covers, with
  injected backup/write closures returning controlled success/failure: full
  success path; backup-read failure (aborts before any live write); backup-
  current-live failure (aborts before any live write); live-write failure
  after backups succeed (verifies rollback re-writes prior live
  credentials); oauthAccount-field-write failure after credentials write
  succeeds (verifies rollback).
- `AccountCaptureTests` — no-op when org uuid is unchanged; refresh-known
  path when uuid matches an existing account; new-account path when uuid
  matches nothing; silent skip on injected Keychain-read failure.
- `CuxStateImporterTests` — full import of a well-formed `state.json` +
  backups; partial import when one account's backup is missing/unreadable
  (that one account marked `needsRelogin`, others still imported); no-op
  when `state.json` is absent; no-op (doesn't re-import) on second run.
- `ReloginCommandTests` (extend existing file) — update the `slot != nil`
  case's expected string from `"cux switch \(slot) && cux /login"` to
  `"claude /login"`; existing `slot == nil` case is unchanged.

The new SwiftUI "Add Account" button in `AccountsSection` is left untested,
consistent with `ClaudeStatusBar` being kept thin per CLAUDE.md — it's a
one-line call to `TerminalLauncher.run`, no logic of its own.

## Out of scope

- A native OAuth client (this app never talks to Anthropic's auth endpoints
  directly — all logins still go through the real `claude /login` browser
  flow).
- Removing the `cux` binary dependency for usage fetching — already
  cux-independent, unaffected by this change.
- Any UI for manually editing/removing a captured account beyond what
  `AccountsSection` already offers (switch, relogin) — add/remove account
  *lifecycle* beyond capture-on-login and existing removal (if any) is not
  addressed here.
- Real-time (sub-poll-interval) capture — the ~60s background poll plus
  popover-open check is the full latency budget; no push/callback mechanism
  is added.
- Migrating away from cux's `"cux-backup"` Keychain service entries
  themselves (i.e. deleting them after import) — first-run migration only
  reads them; cleanup of cux's own Keychain items is not this feature's
  responsibility.
