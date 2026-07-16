# Native Account Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `cux switch` with a native Swift implementation (`StatusBarCore/Accounts/`) that adds, switches, and re-logs-in Claude accounts directly against the macOS Keychain and `~/.claude.json`, with no shelling out to `cux` for switching. Existing cux-managed accounts migrate in automatically on first run.

**Architecture:** Six new `StatusBarCore` components (`NativeAccountStore`, `AccountCredentialVault`, `LiveCredentialWriter`, `NativeAccountSwitcher`, `AccountCapture`, `CuxStateImporter`) sit alongside the existing `AccountDiscovery`/`CuxAccountSwitcher` machinery. `AppState` gains a `resolveAccounts()` helper that prefers the native account list once it has any entries (from migration or a captured login), falling back to the untouched `AccountDiscovery.discover(...)` path for users who have never used cux and have no native accounts yet. Every Keychain/filesystem touchpoint is behind an injectable closure, matching the existing `CuxAccountSwitcher`/`CuxRefresher`/`TokenResolution` pattern.

**Tech Stack:** Swift 6 (`.v5` language mode), Security framework (`SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete`, `SecAccessCreate`/`SecTrustedApplicationCreateFromPath`), Foundation `JSONEncoder`/`JSONDecoder`, swift-testing `0.12.0` (`@Test`/`#expect`/`#require` only — no exit tests, no custom traits).

## Global Constraints

- New logic goes in `StatusBarCore` with a matching test file — one file per source file, per `CLAUDE.md`. `ClaudeStatusBar`-target changes (`AppState.swift`, `AccountsSection.swift`) have no dedicated tests; verify with `make build` (this matches the existing project convention — those files "don't contain logic worth unit-testing on their own").
- Every Keychain read/write and every filesystem read/write in new code must be an injectable closure with a real default implementation — no new code may hit the Keychain or disk in a way a test can't override.
- `Account` struct and all existing UI beyond the additions below are unchanged. `slot` stops meaning "cux slot number" and starts meaning "this app is managing this account, with an app-internal index" — only a not-yet-captured account has `slot == nil`.
- OAuth tokens are read at request time only, kept in a local variable, never logged/cached/written elsewhere (`AppState.token` — see `CLAUDE.md`). The vault stores *credential backups* (deliberately, for restore-on-switch), which is a distinct, already-approved exception documented in the spec's Security considerations section — do not extend logging/caching to any other token path.
- `AccountCredentialVault`'s Keychain service is `"ClaudeStatusBar-backup"`. `LiveCredentialWriter`'s service is `"Claude Code-credentials"` (the live item `claude` itself reads).
- Diagnostics for switch failures go to `native-switch.log` under `AppPaths().root`, mirroring `CuxAccountSwitcher`'s `cux-switch.log`.
- Migration/capture failures are non-fatal: one unreadable account must not block importing the rest; a failed capture is logged and skipped silently (no user-facing error).
- Out of scope (do not implement): native OAuth client, manual account-editing UI beyond switch/relogin/add, real-time (non-polled) capture, cleaning up cux's own Keychain items after migration.

---

### Task 1: `AccountDiscovery.emailAddress(from:)` helper

**Files:**
- Modify: `Sources/StatusBarCore/Accounts/AccountDiscovery.swift`
- Test: `Tests/StatusBarCoreTests/AccountDiscoveryTests.swift`

**Interfaces:**
- Consumes: nothing new — `AccountDiscovery.organizationUuid(from:)` already exists at `Sources/StatusBarCore/Accounts/AccountDiscovery.swift` for the JSON-parsing style to match.
- Produces: `AccountDiscovery.emailAddress(from data: Data) -> String?`, used by Task 8 (`AccountCapture`) to derive a captured account's email from the raw `~/.claude.json` `"oauthAccount"` block (which is expected to carry an `"emailAddress"` string field — the CLI's own account-profile block, populated post-login).

- [ ] **Step 1: Write the failing test**

```swift
@Test func emailAddressReadsFromFlatBlock() {
    let json = #"{"emailAddress":"dev@example.com","organizationUuid":"org-1"}"#
    let data = Data(json.utf8)
    #expect(AccountDiscovery.emailAddress(from: data) == "dev@example.com")
}

@Test func emailAddressReturnsNilWhenMissing() {
    let data = Data(#"{"organizationUuid":"org-1"}"#.utf8)
    #expect(AccountDiscovery.emailAddress(from: data) == nil)
}
```

Add these to `Tests/StatusBarCoreTests/AccountDiscoveryTests.swift`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AccountDiscoveryTests`
Expected: FAIL — `emailAddress` is not a member of `AccountDiscovery`.

- [ ] **Step 3: Write minimal implementation**

Add to `Sources/StatusBarCore/Accounts/AccountDiscovery.swift`, directly below `organizationUuid(from:)`:

```swift
    public static func emailAddress(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["emailAddress"] as? String
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AccountDiscoveryTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Accounts/AccountDiscovery.swift Tests/StatusBarCoreTests/AccountDiscoveryTests.swift
git commit -m "feat(accounts): add AccountDiscovery.emailAddress(from:) helper"
```

---

### Task 2: `NativeAccountStore`

**Files:**
- Create: `Sources/StatusBarCore/Accounts/NativeAccountStore.swift`
- Test: `Tests/StatusBarCoreTests/NativeAccountStoreTests.swift`

**Interfaces:**
- Consumes: `Account` (existing, `Sources/StatusBarCore/Accounts/AccountDiscovery.swift`) — full memberwise init `Account(id:alias:email:slot:isActive:oauthURL:organizationUuid:)`. `AtomicFile.write(_:to:)` (existing, `Sources/StatusBarCore/AtomicFile.swift`).
- Produces: `NativeAccount` (struct: `id: String`, `alias: String?`, `email: String?`, `slot: Int`, `organizationUuid: String?`, `needsRelogin: Bool`), `NativeAccountState` (struct: `activeId: String?`, `accounts: [NativeAccount]`), `NativeAccountStore.exists(file:) -> Bool`, `.load(file:) -> NativeAccountState`, `.save(_:to:) throws`, `.nextSlot(in:) -> Int`, `.toAccount(_:state:) -> Account`, `.toAccounts(_:) -> [Account]`. All of Tasks 5, 7, 8, and 10 depend on these exact names and signatures.

- [ ] **Step 1: Write the failing tests**

Create `Tests/StatusBarCoreTests/NativeAccountStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

@Suite struct NativeAccountStoreTests {
    @Test func existsIsFalseForMissingFile() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        #expect(NativeAccountStore.exists(file: file) == false)
    }

    @Test func loadReturnsEmptyStateWhenFileMissing() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        let state = NativeAccountStore.load(file: file)
        #expect(state.activeId == nil)
        #expect(state.accounts.isEmpty)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }

        let account = NativeAccount(id: "native-0", alias: "Work", email: "dev@example.com",
                                    slot: 0, organizationUuid: "org-1", needsRelogin: false)
        let state = NativeAccountState(activeId: "native-0", accounts: [account])
        try NativeAccountStore.save(state, to: file)

        #expect(NativeAccountStore.exists(file: file))
        let loaded = NativeAccountStore.load(file: file)
        #expect(loaded == state)
    }

    @Test func nextSlotIsOneMoreThanHighestExisting() {
        let state = NativeAccountState(activeId: nil, accounts: [
            NativeAccount(id: "a", alias: nil, email: nil, slot: 0, organizationUuid: nil, needsRelogin: false),
            NativeAccount(id: "b", alias: nil, email: nil, slot: 2, organizationUuid: nil, needsRelogin: false),
        ])
        #expect(NativeAccountStore.nextSlot(in: state) == 3)
    }

    @Test func nextSlotIsZeroWhenEmpty() {
        #expect(NativeAccountStore.nextSlot(in: NativeAccountState()) == 0)
    }

    @Test func toAccountMarksActiveIdAsActive() {
        let account = NativeAccount(id: "native-1", alias: nil, email: "a@b.com",
                                    slot: 1, organizationUuid: "org-1", needsRelogin: true)
        let state = NativeAccountState(activeId: "native-1", accounts: [account])
        let converted = NativeAccountStore.toAccount(account, state: state)
        #expect(converted.id == "native-1")
        #expect(converted.isActive)
        #expect(converted.slot == 1)
        #expect(converted.oauthURL == URL(fileURLWithPath: "/dev/null"))
    }

    @Test func toAccountsSortsBySlot() {
        let state = NativeAccountState(activeId: "b", accounts: [
            NativeAccount(id: "b", alias: nil, email: nil, slot: 1, organizationUuid: nil, needsRelogin: false),
            NativeAccount(id: "a", alias: nil, email: nil, slot: 0, organizationUuid: nil, needsRelogin: false),
        ])
        let accounts = NativeAccountStore.toAccounts(state)
        #expect(accounts.map(\.id) == ["a", "b"])
        #expect(accounts.map(\.isActive) == [false, true])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NativeAccountStoreTests`
Expected: FAIL — no such module member `NativeAccountStore`/`NativeAccount`/`NativeAccountState`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/StatusBarCore/Accounts/NativeAccountStore.swift`:

```swift
import Foundation

public struct NativeAccount: Codable, Sendable, Equatable {
    public var id: String
    public var alias: String?
    public var email: String?
    public var slot: Int
    public var organizationUuid: String?
    public var needsRelogin: Bool

    public init(id: String, alias: String?, email: String?, slot: Int,
                organizationUuid: String?, needsRelogin: Bool) {
        self.id = id
        self.alias = alias
        self.email = email
        self.slot = slot
        self.organizationUuid = organizationUuid
        self.needsRelogin = needsRelogin
    }
}

public struct NativeAccountState: Codable, Sendable, Equatable {
    public var activeId: String?
    public var accounts: [NativeAccount]

    public init(activeId: String? = nil, accounts: [NativeAccount] = []) {
        self.activeId = activeId
        self.accounts = accounts
    }
}

/// Persists the app's own account list at `native-accounts.json` under
/// `AppPaths().root`, independent of cux's `~/.cux/state.json`.
public enum NativeAccountStore {
    public static func exists(file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    public static func load(file: URL) -> NativeAccountState {
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONDecoder().decode(NativeAccountState.self, from: data)
        else { return NativeAccountState() }
        return state
    }

    public static func save(_ state: NativeAccountState, to file: URL) throws {
        let data = try JSONEncoder().encode(state)
        try AtomicFile.write(data, to: file)
    }

    public static func nextSlot(in state: NativeAccountState) -> Int {
        (state.accounts.map(\.slot).max() ?? -1) + 1
    }

    public static func toAccount(_ account: NativeAccount, state: NativeAccountState) -> Account {
        Account(id: account.id, alias: account.alias, email: account.email, slot: account.slot,
                isActive: account.id == state.activeId,
                oauthURL: URL(fileURLWithPath: "/dev/null"),
                organizationUuid: account.organizationUuid)
    }

    public static func toAccounts(_ state: NativeAccountState) -> [Account] {
        state.accounts.sorted { $0.slot < $1.slot }.map { toAccount($0, state: state) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NativeAccountStoreTests`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Accounts/NativeAccountStore.swift Tests/StatusBarCoreTests/NativeAccountStoreTests.swift
git commit -m "feat(accounts): add NativeAccountStore for app-owned account persistence"
```

---

### Task 3: `AccountCredentialVault` + `CredentialBackup`

**Files:**
- Create: `Sources/StatusBarCore/Accounts/AccountCredentialVault.swift`
- Test: `Tests/StatusBarCoreTests/AccountCredentialVaultTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `CredentialBackup` (struct: `liveCredentials: Data`, `oauthAccountBlock: Data?`, both via memberwise `init(liveCredentials:oauthAccountBlock:)`), `AccountCredentialVault.service` (`"ClaudeStatusBar-backup"`), `.read(accountId:reader:) -> CredentialBackup?`, `.write(accountId:_:writer:) -> Bool`. Tasks 5, 7, 8 depend on `CredentialBackup`'s two fields and on calling `.read`/`.write` (wrapped in a zero/two-arg closure — see the note in Task 5 about why these must NOT be referenced bare).

- [ ] **Step 1: Write the failing tests**

Create `Tests/StatusBarCoreTests/AccountCredentialVaultTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

@Suite struct AccountCredentialVaultTests {
    @Test func writeThenReadRoundTripsThroughInjectedStorage() {
        var storage: [String: Data] = [:]
        let writer: (Data, String, String) -> Bool = { data, service, account in
            storage["\(service)/\(account)"] = data
            return true
        }
        let reader: (String, String) -> Data? = { service, account in
            storage["\(service)/\(account)"]
        }

        let backup = CredentialBackup(liveCredentials: Data("creds".utf8),
                                      oauthAccountBlock: Data("oauth".utf8))
        #expect(AccountCredentialVault.write(accountId: "native-0", backup, writer: writer))

        let read = AccountCredentialVault.read(accountId: "native-0", reader: reader)
        #expect(read == backup)
    }

    @Test func readReturnsNilWhenNothingStored() {
        let reader: (String, String) -> Data? = { _, _ in nil }
        #expect(AccountCredentialVault.read(accountId: "missing", reader: reader) == nil)
    }

    @Test func writeFailsWhenWriterFails() {
        let writer: (Data, String, String) -> Bool = { _, _, _ in false }
        let backup = CredentialBackup(liveCredentials: Data("creds".utf8), oauthAccountBlock: nil)
        #expect(AccountCredentialVault.write(accountId: "native-0", backup, writer: writer) == false)
    }

    @Test func oauthAccountBlockRoundTripsAsNil() {
        var storage: [String: Data] = [:]
        let writer: (Data, String, String) -> Bool = { data, service, account in
            storage["\(service)/\(account)"] = data
            return true
        }
        let reader: (String, String) -> Data? = { service, account in
            storage["\(service)/\(account)"]
        }
        let backup = CredentialBackup(liveCredentials: Data("creds".utf8), oauthAccountBlock: nil)
        #expect(AccountCredentialVault.write(accountId: "native-0", backup, writer: writer))
        #expect(AccountCredentialVault.read(accountId: "native-0", reader: reader)?.oauthAccountBlock == nil)
    }

    @Test func serviceNameIsStable() {
        #expect(AccountCredentialVault.service == "ClaudeStatusBar-backup")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AccountCredentialVaultTests`
Expected: FAIL — no such type `CredentialBackup`/`AccountCredentialVault`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/StatusBarCore/Accounts/AccountCredentialVault.swift`:

```swift
import Foundation
import Security

/// One account's backed-up live state: the credential blob normally stored
/// under the `"Claude Code-credentials"` Keychain service, plus the
/// `"oauthAccount"` JSON block normally stored in `~/.claude.json`. Bundled
/// into one vault entry so a switch only ever backs up/restores one thing
/// per account, not two independently-failable things.
public struct CredentialBackup: Codable, Sendable, Equatable {
    public let liveCredentials: Data
    public let oauthAccountBlock: Data?

    public init(liveCredentials: Data, oauthAccountBlock: Data?) {
        self.liveCredentials = liveCredentials
        self.oauthAccountBlock = oauthAccountBlock
    }
}

/// Stores per-account `CredentialBackup`s in the macOS Keychain under a
/// service distinct from the live credential item, so backups get their own
/// (tighter, app-only) ACL rather than sharing the live item's trust list.
public enum AccountCredentialVault {
    public static let service = "ClaudeStatusBar-backup"

    public static func read(
        accountId: String,
        reader: (String, String) -> Data? = defaultReader
    ) -> CredentialBackup? {
        guard let data = reader(service, accountId) else { return nil }
        return try? JSONDecoder().decode(CredentialBackup.self, from: data)
    }

    public static func write(
        accountId: String,
        _ backup: CredentialBackup,
        writer: (Data, String, String) -> Bool = defaultWriter
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(backup) else { return false }
        return writer(data, service, accountId)
    }

    public static func defaultReader(service: String, accountId: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }

    public static func defaultWriter(data: Data, service: String, accountId: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
            kSecAttrAccount as String: accountId,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AccountCredentialVaultTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Accounts/AccountCredentialVault.swift Tests/StatusBarCoreTests/AccountCredentialVaultTests.swift
git commit -m "feat(accounts): add AccountCredentialVault for per-account backup storage"
```

---

### Task 4: `LiveCredentialWriter`

**Files:**
- Create: `Sources/StatusBarCore/Accounts/LiveCredentialWriter.swift`
- Test: `Tests/StatusBarCoreTests/LiveCredentialWriterTests.swift`

**Interfaces:**
- Consumes: `AccountDiscovery.defaultKeychainReader(service:) -> Data?` (existing, `Sources/StatusBarCore/Accounts/AccountDiscovery.swift`).
- Produces: `LiveCredentialWriter.service` (`"Claude Code-credentials"`), `.read(reader:) -> Data?`, `.write(_:trustedPaths:writer:) -> Bool`, `.trustedPaths(thisAppPath:claudePath:) -> [String]`, `.claudeBinaryCandidates: [String]`, `.resolvedClaudePath(candidates:isExecutable:) -> String?`. Task 5 depends on all of these exact names.

- [ ] **Step 1: Write the failing tests**

Create `Tests/StatusBarCoreTests/LiveCredentialWriterTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

@Suite struct LiveCredentialWriterTests {
    @Test func readDelegatesToInjectedReader() {
        let result = LiveCredentialWriter.read(reader: { service in
            service == LiveCredentialWriter.service ? Data("token".utf8) : nil
        })
        #expect(result == Data("token".utf8))
    }

    @Test func readReturnsNilWhenReaderReturnsNil() {
        #expect(LiveCredentialWriter.read(reader: { _ in nil }) == nil)
    }

    @Test func writePassesDataTrustedPathsAndServiceThrough() {
        var captured: (Data, [String], String)?
        let ok = LiveCredentialWriter.write(Data("token".utf8), trustedPaths: ["/bin/claude"]) { data, paths, service in
            captured = (data, paths, service)
            return true
        }
        #expect(ok)
        #expect(captured?.0 == Data("token".utf8))
        #expect(captured?.1 == ["/bin/claude"])
        #expect(captured?.2 == LiveCredentialWriter.service)
    }

    @Test func writeFailsWhenWriterFails() {
        let ok = LiveCredentialWriter.write(Data(), trustedPaths: []) { _, _, _ in false }
        #expect(ok == false)
    }

    @Test func trustedPathsDropsNilClaudePath() {
        let paths = LiveCredentialWriter.trustedPaths(thisAppPath: "/Applications/App.app", claudePath: nil)
        #expect(paths == ["/Applications/App.app"])
    }

    @Test func trustedPathsIncludesBothWhenPresent() {
        let paths = LiveCredentialWriter.trustedPaths(thisAppPath: "/Applications/App.app",
                                                       claudePath: "/opt/homebrew/bin/claude")
        #expect(paths == ["/Applications/App.app", "/opt/homebrew/bin/claude"])
    }

    @Test func resolvedClaudePathReturnsFirstExecutableCandidate() {
        let path = LiveCredentialWriter.resolvedClaudePath(
            candidates: ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"],
            isExecutable: { $0 == "/opt/homebrew/bin/claude" }
        )
        #expect(path == "/opt/homebrew/bin/claude")
    }

    @Test func resolvedClaudePathReturnsNilWhenNoCandidateExecutable() {
        let path = LiveCredentialWriter.resolvedClaudePath(candidates: ["/usr/local/bin/claude"],
                                                           isExecutable: { _ in false })
        #expect(path == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LiveCredentialWriterTests`
Expected: FAIL — no such type `LiveCredentialWriter`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/StatusBarCore/Accounts/LiveCredentialWriter.swift`:

```swift
import Foundation
import Security

/// Reads and writes the live `"Claude Code-credentials"` Keychain item —
/// the same item `claude` itself reads. Writing sets an explicit
/// `SecAccess`/`SecTrustedApplication` ACL naming both `claude` and this app,
/// rather than the default single-writer ACL `security add-generic-password
/// -U` leaves behind (that reset is the root cause of the intermittent
/// Keychain re-prompt cux used to cause).
public enum LiveCredentialWriter {
    public static let service = "Claude Code-credentials"

    public static func read(reader: (String) -> Data? = AccountDiscovery.defaultKeychainReader) -> Data? {
        reader(service)
    }

    public static func write(
        _ data: Data,
        trustedPaths: [String],
        writer: (Data, [String], String) -> Bool = defaultWrite
    ) -> Bool {
        writer(data, trustedPaths, service)
    }

    public static func defaultWrite(data: Data, trustedPaths: [String], service: String) -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let trustedApps: [SecTrustedApplication] = trustedPaths.compactMap { path in
            var app: SecTrustedApplication?
            SecTrustedApplicationCreateFromPath(path, &app)
            return app
        }
        var access: SecAccess?
        SecAccessCreate(service as CFString, trustedApps as CFArray, &access)

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if let access {
            attributes[kSecAttrAccess as String] = access
        }
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Non-nil entries only — `claudePath` is nil when `claude`'s binary
    /// can't be resolved (see `resolvedClaudePath`), in which case the live
    /// item's ACL falls back to app-only trust.
    public static func trustedPaths(thisAppPath: String, claudePath: String?) -> [String] {
        [thisAppPath, claudePath].compactMap { $0 }
    }

    public static let claudeBinaryCandidates: [String] = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/local/claude").path,
    ]

    public static func resolvedClaudePath(
        candidates: [String] = claudeBinaryCandidates,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        candidates.first(where: isExecutable)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LiveCredentialWriterTests`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Accounts/LiveCredentialWriter.swift Tests/StatusBarCoreTests/LiveCredentialWriterTests.swift
git commit -m "feat(accounts): add LiveCredentialWriter for the live credentials Keychain item"
```

---

### Task 5: `NativeAccountSwitcher`

**Files:**
- Create: `Sources/StatusBarCore/Accounts/NativeAccountSwitcher.swift`
- Test: `Tests/StatusBarCoreTests/NativeAccountSwitcherTests.swift`

**Interfaces:**
- Consumes: `NativeAccountState`/`NativeAccountStore.load(file:)`/`.save(_:to:)` (Task 2), `CredentialBackup`/`AccountCredentialVault.read(accountId:reader:)`/`.write(accountId:_:writer:)` (Task 3), `LiveCredentialWriter.read(reader:)`/`.write(_:trustedPaths:writer:)`/`.trustedPaths(thisAppPath:claudePath:)`/`.resolvedClaudePath()` (Task 4), `Account` (existing).
- Produces: `NativeAccountSwitcher` (actor), `.switchTo(account:) async -> Bool`. Task 10 (`AppState`) depends on this exact method name/signature, matching `CuxAccountSwitcher.switchTo(slot:) async -> Bool`'s call shape.

**Important gotcha this task must respect:** Swift does not apply a function's default parameter values when the function is referenced *as a value* (only when called directly). `AccountCredentialVault.read` referenced bare has type `(String, (String, String) -> Data?) -> CredentialBackup?`, not `(String) -> CredentialBackup?` — it will not compile as a default argument of that narrower type. Every default closure below that calls into a function with its own defaulted extra parameters must be wrapped in an explicit closure that omits them, as shown.

- [ ] **Step 1: Write the failing tests**

Create `Tests/StatusBarCoreTests/NativeAccountSwitcherTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

@Suite struct NativeAccountSwitcherTests {
    private func makeState() -> NativeAccountState {
        NativeAccountState(activeId: "native-0", accounts: [
            NativeAccount(id: "native-0", alias: nil, email: "a@example.com", slot: 0,
                         organizationUuid: "org-a", needsRelogin: false),
            NativeAccount(id: "native-1", alias: nil, email: "b@example.com", slot: 1,
                         organizationUuid: "org-b", needsRelogin: false),
        ])
    }

    private func account(_ id: String, state: NativeAccountState) -> Account {
        NativeAccountStore.toAccount(state.accounts.first { $0.id == id }!, state: state)
    }

    @Test func switchingToAlreadyActiveAccountIsHarmlessNoOp() async {
        let state = makeState()
        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in nil },
            writeVaultBackup: { _, _ in false },
            readLiveCredentials: { nil },
            writeLiveCredentials: { _ in false },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in false },
            loadState: { _ in state },
            saveState: { _, _ in false }
        )
        let result = await switcher.switchTo(account: account("native-0", state: state))
        #expect(result)
    }

    @Test func fullSuccessSwapsCredentialsAndUpdatesState() async {
        let state = makeState()
        var vault: [String: CredentialBackup] = [
            "native-1": CredentialBackup(liveCredentials: Data("target-creds".utf8),
                                         oauthAccountBlock: Data("target-oauth".utf8)),
        ]
        var liveCredentials = Data("current-creds".utf8)
        var liveOauthBlock: Data? = Data("current-oauth".utf8)
        var savedState: NativeAccountState?

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { vault[$0] },
            writeVaultBackup: { id, backup in vault[id] = backup; return true },
            readLiveCredentials: { liveCredentials },
            writeLiveCredentials: { data in liveCredentials = data; return true },
            readLiveOauthBlock: { liveOauthBlock },
            writeLiveOauthBlock: { data in liveOauthBlock = data; return true },
            loadState: { _ in state },
            saveState: { newState, _ in savedState = newState; return true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))

        #expect(result)
        #expect(liveCredentials == Data("target-creds".utf8))
        #expect(liveOauthBlock == Data("target-oauth".utf8))
        #expect(savedState?.activeId == "native-1")
        #expect(vault["native-0"]?.liveCredentials == Data("current-creds".utf8))
        #expect(vault["native-0"]?.oauthAccountBlock == Data("current-oauth".utf8))
    }

    @Test func backupReadFailureAbortsBeforeAnyLiveWrite() async {
        let state = makeState()
        var liveCredentials = Data("current-creds".utf8)
        var writeLiveCalled = false

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in nil },
            writeVaultBackup: { _, _ in true },
            readLiveCredentials: { liveCredentials },
            writeLiveCredentials: { data in writeLiveCalled = true; liveCredentials = data; return true },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result == false)
        #expect(writeLiveCalled == false)
    }

    @Test func backupOfOutgoingAccountFailureAbortsBeforeLiveWrite() async {
        let state = makeState()
        var writeLiveCalled = false
        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("target".utf8), oauthAccountBlock: nil) },
            writeVaultBackup: { _, _ in false },
            readLiveCredentials: { Data("current".utf8) },
            writeLiveCredentials: { _ in writeLiveCalled = true; return true },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result == false)
        #expect(writeLiveCalled == false)
    }

    @Test func liveCredentialsWriteFailureAbortsWithoutRollback() async {
        let state = makeState()
        var liveCredentials = Data("current".utf8)
        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("target".utf8), oauthAccountBlock: nil) },
            writeVaultBackup: { _, _ in true },
            readLiveCredentials: { liveCredentials },
            writeLiveCredentials: { _ in false },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result == false)
        // Nothing was ever overwritten live, so there's nothing to roll back —
        // the pre-switch value must be exactly what it was before the call.
        #expect(liveCredentials == Data("current".utf8))
    }

    @Test func oauthBlockWriteFailureRollsBackCredentialsAndOauthBlock() async {
        let state = makeState()
        var liveCredentials = Data("current-creds".utf8)
        var liveOauthBlock: Data? = Data("current-oauth".utf8)

        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("target-creds".utf8),
                                                     oauthAccountBlock: Data("target-oauth".utf8)) },
            writeVaultBackup: { _, _ in true },
            readLiveCredentials: { liveCredentials },
            writeLiveCredentials: { data in liveCredentials = data; return true },
            readLiveOauthBlock: { liveOauthBlock },
            writeLiveOauthBlock: { data in
                if data == Data("target-oauth".utf8) { return false }
                liveOauthBlock = data
                return true
            },
            loadState: { _ in state },
            saveState: { _, _ in true }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result == false)
        #expect(liveCredentials == Data("current-creds".utf8))
        #expect(liveOauthBlock == Data("current-oauth".utf8))
    }

    @Test func stateSaveFailureAfterSuccessfulLiveSwapReturnsFalse() async {
        let state = makeState()
        let switcher = NativeAccountSwitcher(
            stateFile: URL(fileURLWithPath: "/dev/null"),
            diagnosticLog: nil,
            readVaultBackup: { _ in CredentialBackup(liveCredentials: Data("target".utf8), oauthAccountBlock: nil) },
            writeVaultBackup: { _, _ in true },
            readLiveCredentials: { Data("current".utf8) },
            writeLiveCredentials: { _ in true },
            readLiveOauthBlock: { nil },
            writeLiveOauthBlock: { _ in true },
            loadState: { _ in state },
            saveState: { _, _ in false }
        )

        let result = await switcher.switchTo(account: account("native-1", state: state))
        #expect(result == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NativeAccountSwitcherTests`
Expected: FAIL — no such type `NativeAccountSwitcher`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/StatusBarCore/Accounts/NativeAccountSwitcher.swift`:

```swift
import Foundation

/// Switches the active Claude account by writing directly to the
/// `"Claude Code-credentials"` Keychain item and `~/.claude.json`'s
/// `"oauthAccount"` block, mirroring cux's `SwitchTo` staging order:
/// read target backup -> back up outgoing live state -> write target live
/// credentials -> write target live oauthAccount block (rolling back the
/// credentials write if this fails) -> persist the new active id.
public actor NativeAccountSwitcher {
    private let stateFile: URL
    private let diagnosticLog: URL?
    private let readVaultBackup: (String) -> CredentialBackup?
    private let writeVaultBackup: (String, CredentialBackup) -> Bool
    private let readLiveCredentials: () -> Data?
    private let writeLiveCredentials: (Data) -> Bool
    private let readLiveOauthBlock: () -> Data?
    private let writeLiveOauthBlock: (Data?) -> Bool
    private let loadState: (URL) -> NativeAccountState
    private let saveState: (NativeAccountState, URL) -> Bool

    public init(
        stateFile: URL = AppPaths().root.appendingPathComponent("native-accounts.json"),
        diagnosticLog: URL? = AppPaths().root.appendingPathComponent("native-switch.log"),
        readVaultBackup: @escaping (String) -> CredentialBackup? = { AccountCredentialVault.read(accountId: $0) },
        writeVaultBackup: @escaping (String, CredentialBackup) -> Bool = { AccountCredentialVault.write(accountId: $0, $1) },
        readLiveCredentials: @escaping () -> Data? = { LiveCredentialWriter.read() },
        writeLiveCredentials: @escaping (Data) -> Bool = { data in
            LiveCredentialWriter.write(data, trustedPaths: LiveCredentialWriter.trustedPaths(
                thisAppPath: Bundle.main.bundlePath,
                claudePath: LiveCredentialWriter.resolvedClaudePath()))
        },
        readLiveOauthBlock: @escaping () -> Data? = { NativeAccountSwitcher.defaultReadLiveOauthBlock() },
        writeLiveOauthBlock: @escaping (Data?) -> Bool = { blockData in
            guard let blockData else { return true }
            return NativeAccountSwitcher.defaultWriteLiveOauthBlock(blockData)
        },
        loadState: @escaping (URL) -> NativeAccountState = NativeAccountStore.load,
        saveState: @escaping (NativeAccountState, URL) -> Bool = { state, file in
            (try? NativeAccountStore.save(state, to: file)) != nil
        }
    ) {
        self.stateFile = stateFile
        self.diagnosticLog = diagnosticLog
        self.readVaultBackup = readVaultBackup
        self.writeVaultBackup = writeVaultBackup
        self.readLiveCredentials = readLiveCredentials
        self.writeLiveCredentials = writeLiveCredentials
        self.readLiveOauthBlock = readLiveOauthBlock
        self.writeLiveOauthBlock = writeLiveOauthBlock
        self.loadState = loadState
        self.saveState = saveState
    }

    public func switchTo(account: Account) async -> Bool {
        let state = loadState(stateFile)
        guard state.activeId != account.id else { return true }

        guard let backup = readVaultBackup(account.id) else {
            writeDiagnostic("switch to \(account.id) failed: no backup credentials found")
            return false
        }

        guard let currentLiveCredentials = readLiveCredentials() else {
            writeDiagnostic("switch to \(account.id) failed: could not read current live credentials")
            return false
        }
        let currentLiveOauthBlock = readLiveOauthBlock()

        if let outgoingId = state.activeId {
            let outgoingBackup = CredentialBackup(liveCredentials: currentLiveCredentials,
                                                  oauthAccountBlock: currentLiveOauthBlock)
            guard writeVaultBackup(outgoingId, outgoingBackup) else {
                writeDiagnostic("switch to \(account.id) failed: could not back up outgoing account \(outgoingId)")
                return false
            }
        }

        guard writeLiveCredentials(backup.liveCredentials) else {
            writeDiagnostic("switch to \(account.id) failed: could not write live credentials")
            return false
        }

        guard writeLiveOauthBlock(backup.oauthAccountBlock) else {
            _ = writeLiveCredentials(currentLiveCredentials)
            _ = writeLiveOauthBlock(currentLiveOauthBlock)
            writeDiagnostic("switch to \(account.id) failed: could not write oauthAccount block, rolled back")
            return false
        }

        var newState = state
        newState.activeId = account.id
        guard saveState(newState, stateFile) else {
            writeDiagnostic("switch to \(account.id): live swap succeeded but state save failed")
            return false
        }

        writeDiagnostic("switch to \(account.id) succeeded")
        return true
    }

    private func writeDiagnostic(_ message: String) {
        guard let diagnosticLog else { return }
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: diagnosticLog) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: diagnosticLog)
        }
    }

    /// `~/.claude.json`'s top-level `"oauthAccount"` key, treated as an
    /// opaque JSON sub-object exactly as cux does — this app never
    /// interprets its fields except via `AccountDiscovery.emailAddress(from:)`
    /// / `.organizationUuid(from:)` when capturing a brand-new login.
    static func defaultReadLiveOauthBlock(
        configFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    ) -> Data? {
        guard let data = try? Data(contentsOf: configFile),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = obj["oauthAccount"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: block)
    }

    static func defaultWriteLiveOauthBlock(
        _ blockData: Data,
        configFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    ) -> Bool {
        guard let blockObj = try? JSONSerialization.jsonObject(with: blockData) else { return false }
        var config: [String: Any] = [:]
        if let existing = try? Data(contentsOf: configFile),
           let existingObj = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            config = existingObj
        }
        config["oauthAccount"] = blockObj
        guard let newData = try? JSONSerialization.data(withJSONObject: config) else { return false }
        return (try? AtomicFile.write(newData, to: configFile)) != nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NativeAccountSwitcherTests`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Accounts/NativeAccountSwitcher.swift Tests/StatusBarCoreTests/NativeAccountSwitcherTests.swift
git commit -m "feat(accounts): add NativeAccountSwitcher, a native replacement for cux switch"
```

---

### Task 6: `UsageStore` — preserve `needsRelogin` for native accounts, add `seedNeedsRelogin`

**Files:**
- Modify: `Sources/StatusBarCore/Usage/UsageStore.swift`
- Test: `Tests/StatusBarCoreTests/UsageStoreTests.swift`

**Why this file needs to change (not in the original design spec's Modified-files list):** `UsageStore.refresh`'s `case nil` branch (no token, no cache hit) currently forces `state.needsRelogin = false` whenever `account.slot != nil`, because under the old cux model a `slot`-having account with no cache entry just means "cux hasn't fetched yet," never "logged out." Under the new model, `slot != nil` no longer implies "cux owns auth for this account" — it can mean "a migrated native account with no vault backup" (e.g. `CuxStateImporter` couldn't read that account's cux-backup Keychain item). For that case `AppState` pre-seeds `needsRelogin: true` via the new `seedNeedsRelogin` method below, and this branch must stop clobbering it back to `false`.

**Interfaces:**
- Consumes: nothing new.
- Produces: `UsageStore.seedNeedsRelogin(_ ids: [String]) -> Void` (new public method). Task 10 (`AppState.resolveAccounts()`) depends on this exact name/signature.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/StatusBarCoreTests/UsageStoreTests.swift`:

```swift
@Test func needsReloginSurvivesACacheMissRefreshCycle() async {
    let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
    store.seedNeedsRelogin(["native-0"])

    let account = Account(id: "native-0", alias: nil, email: nil, slot: 0,
                          isActive: true, oauthURL: URL(fileURLWithPath: "/dev/null"))
    await store.refresh(accounts: [(account: account, token: nil, cached: nil)])

    #expect(store.states["native-0"]?.needsRelogin == true)
}

@Test func freshAccountWithNoPriorStateDefaultsToNoRelogin() async {
    let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
    let account = Account(id: "native-1", alias: nil, email: nil, slot: 1,
                          isActive: false, oauthURL: URL(fileURLWithPath: "/dev/null"))
    await store.refresh(accounts: [(account: account, token: nil, cached: nil)])

    #expect(store.states["native-1"]?.needsRelogin == false)
}

@Test func seedNeedsReloginDoesNotOverwriteExistingState() {
    let store = UsageStore(fetcher: FailingFetcher(), cacheFile: tempCacheFile())
    store.seedNeedsRelogin(["native-0"])
    #expect(store.states["native-0"]?.needsRelogin == true)

    // A second seed call must not stomp state that's since moved on
    // (e.g. a successful fetch already cleared needsRelogin).
    store.seedNeedsRelogin(["native-0"])
    #expect(store.states["native-0"]?.needsRelogin == true)
}
```

Add the small shared test helpers this file needs, if not already present (check the top of `UsageStoreTests.swift` first — `FailingFetcher` and `tempCacheFile()` may already exist from earlier tests in this file; only add what's missing):

```swift
private struct FailingFetcher: UsageFetching {
    func fetch(token: String) async throws -> UsageSnapshot {
        throw UsageError.network
    }
}

private func tempCacheFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UsageStoreTests`
Expected: FAIL — `seedNeedsRelogin` is not a member of `UsageStore`, and (once that's stubbed in) `needsReloginSurvivesACacheMissRefreshCycle` fails because the existing `case nil` branch still clobbers it to `false`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/StatusBarCore/Usage/UsageStore.swift`, inside `refresh(accounts:now:)`, change the `case nil` branch:

```swift
                case nil:  // no token — cux slot account or missing credentials
                    if let cached {
                        let fresh = now.timeIntervalSince(cached.fetchedAt) <= Self.cuxCacheFreshFor
                        state = AccountUsageState(snapshot: cached,
                                                  freshness: fresh ? .fresh : .stale)
                    } else if account.slot != nil {
                        // A slot-having account with no cache hit and no prior
                        // state defaults to needsRelogin == false (via
                        // AccountUsageState()'s own default) — but if this ID
                        // was pre-seeded via seedNeedsRelogin (a migrated
                        // native account with no vault backup), that flag
                        // must survive this cycle, not be reset here.
                    } else {
                        state.needsRelogin = true
                    }
```

Then add the new public method, directly below `refresh(accounts:now:)`:

```swift
    /// Marks the given account ids as needing relogin, without disturbing
    /// any id that already has state (e.g. from a completed fetch). Used by
    /// `AppState.resolveAccounts()` right after loading a migrated native
    /// account whose credential vault backup couldn't be read.
    public func seedNeedsRelogin(_ ids: [String]) {
        for id in ids where states[id] == nil {
            states[id] = AccountUsageState(needsRelogin: true)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UsageStoreTests`
Expected: PASS (all existing tests plus the 3 new ones)

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Usage/UsageStore.swift Tests/StatusBarCoreTests/UsageStoreTests.swift
git commit -m "fix(usage): preserve pre-seeded needsRelogin across cache-miss refresh cycles"
```

---

### Task 7: `CuxStateImporter`

**Files:**
- Create: `Sources/StatusBarCore/Accounts/CuxStateImporter.swift`
- Test: `Tests/StatusBarCoreTests/CuxStateImporterTests.swift`

**Why this can't call `AccountDiscovery.discoverCux`:** `AccountDiscovery.discoverCux(root:)` (`Sources/StatusBarCore/Accounts/AccountDiscovery.swift`) is `private` and returns `[Account]`, not the raw per-slot email/oauth-file/backup-credential data migration needs. Rather than widen `AccountDiscovery`'s API for one caller, this task reimplements the minimal parsing migration needs directly against `~/.cux/state.json` and `~/.cux/accounts/<slot>-<email>/oauth.json`, reusing the exact same zero-padded/plain directory-naming fallback (`"%02d-%@"` then `"\(slot)-\(email)"`) `discoverCux` already establishes as cux's convention.

**Assumption flagged for verification during implementation:** cux's Keychain backup item for a given account is assumed to be labeled `"cux-backup-<02d-slot>-<email>"` (mirroring its directory-naming convention). This wasn't independently confirmed against cux's Go source in this plan. If a real cux installation is available, verify with `security find-generic-password -s "cux-backup-00-someone@example.com"` (a real slot 0 label) before trusting this in production; if the label format differs, only the read step degrades (that account gets `needsRelogin: true` instead of a working backup) — it does not corrupt other migrated accounts, per the "partial import allowed" constraint.

**Interfaces:**
- Consumes: `AccountDiscovery.discover(cuxRoot:credentialsFile:) -> [Account]`, `Account` (existing), `NativeAccountStore.exists(file:)`/`.save(_:to:)` (Task 2), `CredentialBackup`/`AccountCredentialVault.write(accountId:_:writer:)` (Task 3), `NativeAccount`/`NativeAccountState` (Task 2).
- Produces: `CuxStateImporter.importIfNeeded(cuxRoot:nativeStateFile:vaultWrite:)`. Task 10 (`AppState.resolveAccounts()`) depends on this exact name/signature.

- [ ] **Step 1: Write the failing tests**

Create `Tests/StatusBarCoreTests/CuxStateImporterTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

@Suite struct CuxStateImporterTests {
    private func makeCuxRoot(accounts: [(slot: Int, email: String, alias: String?, oauthJSON: String?)],
                             activeSlot: Int?) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accountsDir = root.appendingPathComponent("accounts", isDirectory: true)
        try! FileManager.default.createDirectory(at: accountsDir, withIntermediateDirectories: true)

        var accountsJSON = "{"
        accountsJSON += accounts.map { acct in
            let aliasField = acct.alias.map { "\"\($0)\"" } ?? "null"
            return "\"\(acct.slot)\":{\"slot\":\(acct.slot),\"email\":\"\(acct.email)\",\"alias\":\(aliasField)}"
        }.joined(separator: ",")
        accountsJSON += "}"
        let activeSlotJSON = activeSlot.map(String.init) ?? "null"
        let stateJSON = "{\"activeSlot\":\(activeSlotJSON),\"accounts\":\(accountsJSON)}"
        try! Data(stateJSON.utf8).write(to: root.appendingPathComponent("state.json"))

        for acct in accounts {
            let dirName = String(format: "%02d-%@", acct.slot, acct.email)
            let dir = accountsDir.appendingPathComponent(dirName, isDirectory: true)
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let oauthJSON = acct.oauthJSON {
                try! Data(oauthJSON.utf8).write(to: dir.appendingPathComponent("oauth.json"))
            }
        }
        return root
    }

    @Test func doesNothingIfNativeStateFileAlreadyExists() {
        let cuxRoot = makeCuxRoot(accounts: [(0, "a@example.com", nil, "{}")], activeSlot: 0)
        let nativeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try! Data("{}".utf8).write(to: nativeFile)
        defer { try? FileManager.default.removeItem(at: nativeFile) }

        CuxStateImporter.importIfNeeded(cuxRoot: cuxRoot, nativeStateFile: nativeFile, vaultWrite: { _, _ in true })

        let raw = try! String(contentsOf: nativeFile, encoding: .utf8)
        #expect(raw == "{}")
    }

    @Test func doesNothingWhenNoCuxAccountsExist() {
        let cuxRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nativeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: nativeFile) }

        CuxStateImporter.importIfNeeded(cuxRoot: cuxRoot, nativeStateFile: nativeFile, vaultWrite: { _, _ in true })

        #expect(NativeAccountStore.exists(file: nativeFile) == false)
    }

    @Test func importsAllAccountsAndMarksActiveOne() {
        let cuxRoot = makeCuxRoot(accounts: [
            (0, "a@example.com", "Work", "{\"organizationUuid\":\"org-a\"}"),
            (1, "b@example.com", nil, "{\"organizationUuid\":\"org-b\"}"),
        ], activeSlot: 1)
        let nativeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: nativeFile) }

        CuxStateImporter.importIfNeeded(cuxRoot: cuxRoot, nativeStateFile: nativeFile, vaultWrite: { _, _ in true })

        let state = NativeAccountStore.load(file: nativeFile)
        #expect(state.accounts.count == 2)
        #expect(state.activeId == "slot-1")
        #expect(state.accounts.first { $0.id == "slot-0" }?.alias == "Work")
        #expect(state.accounts.first { $0.id == "slot-0" }?.organizationUuid == "org-a")
        #expect(state.accounts.allSatisfy { $0.needsRelogin == false })
    }

    @Test func oneUnreadableAccountDoesNotBlockImportingTheRest() {
        // Slot 0 has no cux-backup Keychain entry (simulated via vaultWrite
        // failing only for that account) — it should still be imported,
        // just flagged needsRelogin.
        let cuxRoot = makeCuxRoot(accounts: [
            (0, "a@example.com", nil, "{}"),
            (1, "b@example.com", nil, "{}"),
        ], activeSlot: 0)
        let nativeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: nativeFile) }

        CuxStateImporter.importIfNeeded(cuxRoot: cuxRoot, nativeStateFile: nativeFile, vaultWrite: { id, _ in
            id != "slot-0"
        })

        let state = NativeAccountStore.load(file: nativeFile)
        #expect(state.accounts.count == 2)
        #expect(state.accounts.first { $0.id == "slot-0" }?.needsRelogin == true)
        #expect(state.accounts.first { $0.id == "slot-1" }?.needsRelogin == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CuxStateImporterTests`
Expected: FAIL — no such type `CuxStateImporter`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/StatusBarCore/Accounts/CuxStateImporter.swift`:

```swift
import Foundation

/// One-time migration of cux-managed accounts into `NativeAccountStore`.
/// Runs whenever `native-accounts.json` doesn't exist yet; a no-op forever
/// after (even if cux is later uninstalled).
public enum CuxStateImporter {
    public static func importIfNeeded(
        cuxRoot: URL,
        nativeStateFile: URL,
        vaultWrite: (String, CredentialBackup) -> Bool = { AccountCredentialVault.write(accountId: $0, $1) }
    ) {
        guard !NativeAccountStore.exists(file: nativeStateFile) else { return }

        let discovered = AccountDiscovery.discover(cuxRoot: cuxRoot,
                                                    credentialsFile: URL(fileURLWithPath: "/dev/null"))
        let slotAccounts = discovered.filter { $0.slot != nil }
        guard !slotAccounts.isEmpty else { return }

        var accounts: [NativeAccount] = []
        var activeId: String?

        for account in slotAccounts {
            guard let slot = account.slot else { continue }
            let email = account.email ?? ""
            let backupLabel = cuxBackupLabel(slot: slot, email: email)
            let oauthFile = cuxRoot.appendingPathComponent("accounts", isDirectory: true)
                .appendingPathComponent(String(format: "%02d-%@", slot, email))
                .appendingPathComponent("oauth.json")
            let oauthBlock = try? Data(contentsOf: oauthFile)

            let needsRelogin: Bool
            if let liveCreds = AccountDiscovery.defaultKeychainReader(backupLabel) {
                let backup = CredentialBackup(liveCredentials: liveCreds, oauthAccountBlock: oauthBlock)
                needsRelogin = !vaultWrite(account.id, backup)
            } else {
                needsRelogin = true
            }

            accounts.append(NativeAccount(id: account.id, alias: account.alias, email: account.email,
                                          slot: slot, organizationUuid: account.organizationUuid,
                                          needsRelogin: needsRelogin))
            if account.isActive { activeId = account.id }
        }

        guard !accounts.isEmpty else { return }
        try? NativeAccountStore.save(NativeAccountState(activeId: activeId, accounts: accounts), to: nativeStateFile)
    }

    static func cuxBackupLabel(slot: Int, email: String) -> String {
        "cux-backup-\(String(format: "%02d", slot))-\(email)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CuxStateImporterTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Accounts/CuxStateImporter.swift Tests/StatusBarCoreTests/CuxStateImporterTests.swift
git commit -m "feat(accounts): add CuxStateImporter for one-time cux -> native migration"
```

---

### Task 8: `AccountCapture`

**Files:**
- Create: `Sources/StatusBarCore/Accounts/AccountCapture.swift`
- Test: `Tests/StatusBarCoreTests/AccountCaptureTests.swift`

**The first-ever-Add-Account bootstrap problem this task must solve:** a user with no cux and no native accounts yet has only the plain default account (`AccountDiscovery.discover`'s fallback, `slot == nil`). When they click "Add Account" for the first time, `NativeAccountStore` is still empty — drift-detection alone would only ever register the *new* post-login account, silently losing track of the account that was active before. `checkForNewLogin()` below handles this explicitly: if the store is still empty when a new login is detected, it first registers the pre-login baseline snapshot (captured by `beginCapture()` before the browser hand-off) as slot 0, then registers the newly detected login as the next slot and makes it active.

**Interfaces:**
- Consumes: `CredentialBackup`/`AccountCredentialVault.write(accountId:_:writer:)` (Task 3), `LiveCredentialWriter.read(reader:)` (Task 4), `NativeAccountSwitcher.defaultReadLiveOauthBlock()` (Task 5, `internal` — same module, callable), `NativeAccountStore.load(file:)`/`.save(_:to:)`/`.nextSlot(in:)`/`.toAccount(_:state:)` (Task 2), `AccountDiscovery.emailAddress(from:)`/`.organizationUuid(from:)` (Task 1 / existing).
- Produces: `AccountCapture` (actor), `AccountCapture.Result` (enum: `.noChange`, `.captured(Account)`), `.beginCapture() async`, `.checkForNewLogin() async -> Result`. Task 10 (`AppState`) depends on these exact names.

- [ ] **Step 1: Write the failing tests**

Create `Tests/StatusBarCoreTests/AccountCaptureTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

@Suite struct AccountCaptureTests {
    private func makeCapture(
        storeFile: URL,
        liveCredentials: @escaping () -> Data?,
        liveOauthBlock: @escaping () -> Data?,
        vault: inout [String: CredentialBackup]
    ) -> (AccountCapture, () -> [String: CredentialBackup]) {
        var storage = vault
        let capture = AccountCapture(
            storeFile: storeFile,
            readLiveCredentials: liveCredentials,
            readLiveOauthBlock: liveOauthBlock,
            vaultWrite: { id, backup in storage[id] = backup; return true },
            loadState: NativeAccountStore.load,
            saveState: { state, file in (try? NativeAccountStore.save(state, to: file)) != nil }
        )
        vault = storage
        return (capture, { storage })
    }

    @Test func checkForNewLoginIsNoOpWithoutABaseline() async {
        let storeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        var vault: [String: CredentialBackup] = [:]
        let (capture, _) = makeCapture(storeFile: storeFile,
                                       liveCredentials: { Data("anything".utf8) },
                                       liveOauthBlock: { nil }, vault: &vault)

        let result = await capture.checkForNewLogin()
        if case .noChange = result {} else { Issue.record("expected .noChange") }
    }

    @Test func checkForNewLoginIsNoOpWhenCredentialsUnchanged() async {
        let storeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        var vault: [String: CredentialBackup] = [:]
        let (capture, _) = makeCapture(storeFile: storeFile,
                                       liveCredentials: { Data("same".utf8) },
                                       liveOauthBlock: { nil }, vault: &vault)

        await capture.beginCapture()
        let result = await capture.checkForNewLogin()
        if case .noChange = result {} else { Issue.record("expected .noChange") }
    }

    @Test func firstEverAddAccountBootstrapsBaselineAndNewAccount() async {
        let storeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: storeFile) }

        var live = Data("old-creds".utf8)
        var oauth: Data? = Data(#"{"emailAddress":"old@example.com","organizationUuid":"org-old"}"#.utf8)
        var vault: [String: CredentialBackup] = [:]
        let (capture, vaultSnapshot) = makeCapture(storeFile: storeFile,
                                                   liveCredentials: { live },
                                                   liveOauthBlock: { oauth }, vault: &vault)

        await capture.beginCapture()
        // Simulate the browser hand-off completing with a new login.
        live = Data("new-creds".utf8)
        oauth = Data(#"{"emailAddress":"new@example.com","organizationUuid":"org-new"}"#.utf8)

        let result = await capture.checkForNewLogin()
        guard case .captured(let newAccount) = result else {
            Issue.record("expected .captured"); return
        }

        let state = NativeAccountStore.load(file: storeFile)
        #expect(state.accounts.count == 2)
        #expect(state.accounts.first { $0.slot == 0 }?.email == "old@example.com")
        #expect(state.accounts.first { $0.slot == 1 }?.email == "new@example.com")
        #expect(state.activeId == newAccount.id)
        #expect(newAccount.isActive)
        #expect(vaultSnapshot().count == 2)
    }

    @Test func subsequentAddAccountOnlyRegistersTheNewOne() async {
        let storeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: storeFile) }

        let existing = NativeAccountState(activeId: "native-0", accounts: [
            NativeAccount(id: "native-0", alias: nil, email: "old@example.com", slot: 0,
                         organizationUuid: "org-old", needsRelogin: false),
        ])
        try! NativeAccountStore.save(existing, to: storeFile)

        var live = Data("old-creds".utf8)
        var oauth: Data? = nil
        var vault: [String: CredentialBackup] = [:]
        let (capture, _) = makeCapture(storeFile: storeFile, liveCredentials: { live },
                                       liveOauthBlock: { oauth }, vault: &vault)

        await capture.beginCapture()
        live = Data("new-creds".utf8)
        oauth = Data(#"{"emailAddress":"new@example.com","organizationUuid":"org-new"}"#.utf8)

        let result = await capture.checkForNewLogin()
        guard case .captured = result else { Issue.record("expected .captured"); return }

        let state = NativeAccountStore.load(file: storeFile)
        #expect(state.accounts.count == 2)
        #expect(state.accounts.first { $0.slot == 1 }?.email == "new@example.com")
        #expect(state.activeId == "native-1")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AccountCaptureTests`
Expected: FAIL — no such type `AccountCapture`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/StatusBarCore/Accounts/AccountCapture.swift`:

```swift
import Foundation

/// Detects a completed `claude /login` by diffing the live credentials
/// Keychain item against a baseline snapshotted right before the login was
/// launched. Polled from `AppState` on popover-open and on a ~60s ticker
/// (see `AppState.recheckReloginAccounts()`); a no-op whenever no capture
/// is in progress.
public actor AccountCapture {
    public enum Result: Equatable, Sendable {
        case noChange
        case captured(Account)
    }

    private var baseline: CredentialBackup?
    private let storeFile: URL
    private let readLiveCredentials: () -> Data?
    private let readLiveOauthBlock: () -> Data?
    private let vaultWrite: (String, CredentialBackup) -> Bool
    private let loadState: (URL) -> NativeAccountState
    private let saveState: (NativeAccountState, URL) -> Bool

    public init(
        storeFile: URL,
        readLiveCredentials: @escaping () -> Data? = { LiveCredentialWriter.read() },
        readLiveOauthBlock: @escaping () -> Data? = { NativeAccountSwitcher.defaultReadLiveOauthBlock() },
        vaultWrite: @escaping (String, CredentialBackup) -> Bool = { AccountCredentialVault.write(accountId: $0, $1) },
        loadState: @escaping (URL) -> NativeAccountState = NativeAccountStore.load,
        saveState: @escaping (NativeAccountState, URL) -> Bool = { state, file in
            (try? NativeAccountStore.save(state, to: file)) != nil
        }
    ) {
        self.storeFile = storeFile
        self.readLiveCredentials = readLiveCredentials
        self.readLiveOauthBlock = readLiveOauthBlock
        self.vaultWrite = vaultWrite
        self.loadState = loadState
        self.saveState = saveState
    }

    /// Snapshots the currently-live credentials as the "before" baseline.
    /// Call right before launching `claude /login` in Terminal.
    public func beginCapture() {
        guard let creds = readLiveCredentials() else { baseline = nil; return }
        baseline = CredentialBackup(liveCredentials: creds, oauthAccountBlock: readLiveOauthBlock())
    }

    /// Polls the live Keychain item; if it differs from the baseline, a new
    /// login has completed. Registers the new account — and, on a
    /// first-ever capture with an empty store, the pre-capture baseline
    /// account too — into `NativeAccountStore`.
    public func checkForNewLogin() -> Result {
        guard let baseline, let currentCreds = readLiveCredentials(),
              currentCreds != baseline.liveCredentials else { return .noChange }

        var state = loadState(storeFile)
        let currentOauth = readLiveOauthBlock()

        if state.accounts.isEmpty {
            let baselineSlot = NativeAccountStore.nextSlot(in: state)
            let baselineId = "native-\(baselineSlot)"
            _ = vaultWrite(baselineId, baseline)
            state.accounts.append(NativeAccount(
                id: baselineId, alias: nil,
                email: baseline.oauthAccountBlock.flatMap(AccountDiscovery.emailAddress(from:)),
                slot: baselineSlot,
                organizationUuid: baseline.oauthAccountBlock.flatMap(AccountDiscovery.organizationUuid(from:)),
                needsRelogin: false))
            state.activeId = baselineId
        }

        let newSlot = NativeAccountStore.nextSlot(in: state)
        let newId = "native-\(newSlot)"
        let newBackup = CredentialBackup(liveCredentials: currentCreds, oauthAccountBlock: currentOauth)
        _ = vaultWrite(newId, newBackup)
        let newAccount = NativeAccount(
            id: newId, alias: nil,
            email: currentOauth.flatMap(AccountDiscovery.emailAddress(from:)),
            slot: newSlot,
            organizationUuid: currentOauth.flatMap(AccountDiscovery.organizationUuid(from:)),
            needsRelogin: false)
        state.accounts.append(newAccount)
        state.activeId = newId
        self.baseline = nil

        guard saveState(state, storeFile) else { return .noChange }
        return .captured(NativeAccountStore.toAccount(newAccount, state: state))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AccountCaptureTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Accounts/AccountCapture.swift Tests/StatusBarCoreTests/AccountCaptureTests.swift
git commit -m "feat(accounts): add AccountCapture for capture-after-login account adding"
```

---

### Task 9: `ReloginCommand` — bare `claude /login` for managed accounts

**Files:**
- Modify: `Sources/StatusBarCore/Accounts/ReloginCommand.swift`
- Test: `Tests/StatusBarCoreTests/ReloginCommandTests.swift`

**Why:** Today, `ReloginCommand.command(for:)` branches on `account.slot != nil` to build a cux-specific relogin command (targeting a specific cux slot). Under the native model, re-login for *any* tracked account (native or the plain default) is just `claude /login` — `AppState.switchAccount` already puts the right account live in-process before this command ever runs, so the command itself no longer needs to know about slots at all.

**Interfaces:**
- Consumes: `Account` (existing).
- Produces: `ReloginCommand.command(for:) -> String` (signature unchanged; behavior simplified to always return `"claude /login"`). Task 10 depends on `AppState.switchAccount` having already made the target account live before this command is invoked from the UI (see `AccountsSection.swift`'s existing "Log in" button, unchanged wiring).

- [ ] **Step 1: Update the failing test**

Read `Tests/StatusBarCoreTests/ReloginCommandTests.swift` first to confirm its current exact content, then update its first test's expected string (the one that currently expects a cux-slot-specific command) to expect the bare login command for a slotted account, and confirm the no-slot case is unchanged:

```swift
@Test func returnsPlainLoginCommandForAnyAccount() {
    let slotted = Account(id: "native-0", alias: nil, email: "a@example.com", slot: 0,
                          isActive: true, oauthURL: URL(fileURLWithPath: "/dev/null"))
    #expect(ReloginCommand.command(for: slotted) == "claude /login")

    let plain = Account(id: "default", alias: nil, email: nil, slot: nil,
                        isActive: true, oauthURL: URL(fileURLWithPath: "/dev/null"))
    #expect(ReloginCommand.command(for: plain) == "claude /login")
}
```

Remove any now-redundant older test(s) that asserted a slot-specific relogin command string.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReloginCommandTests`
Expected: FAIL — old test still expects a slot-specific string.

- [ ] **Step 3: Write minimal implementation**

Replace the body of `Sources/StatusBarCore/Accounts/ReloginCommand.swift`'s `command(for:)` so it unconditionally returns `"claude /login"` regardless of `account.slot`. Keep the function signature (`public static func command(for account: Account) -> String`) unchanged so `AccountsSection.swift`'s existing call site (`TerminalLauncher.run(ReloginCommand.command(for: account))`) needs no change.

```swift
    public static func command(for account: Account) -> String {
        "claude /login"
    }
```

Remove any now-dead cux-slot-specific branch/helper this replaces.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReloginCommandTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Accounts/ReloginCommand.swift Tests/StatusBarCoreTests/ReloginCommandTests.swift
git commit -m "refactor(accounts): ReloginCommand always returns bare 'claude /login'"
```

---

### Task 10: `AppState` wiring

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppState.swift`

**No dedicated test file** — per `CLAUDE.md`, `ClaudeStatusBar` is kept thin and untested; verify with `make build` and a manual smoke test (steps below).

**Interfaces:**
- Consumes: `CuxStateImporter.importIfNeeded(cuxRoot:nativeStateFile:)` (Task 7), `NativeAccountStore.load(file:)`/`.toAccounts(_:)` (Task 2), `UsageStore.seedNeedsRelogin(_:)` (Task 6), `NativeAccountSwitcher.switchTo(account:)` (Task 5), `AccountCapture.beginCapture()`/`.checkForNewLogin()` (Task 8), `TerminalLauncher.run(_:)` (existing, `Sources/ClaudeStatusBar/TerminalLauncher.swift`).
- Produces: `AppState.beginAddAccount() async` — Task 11 (`AccountsSection`'s new "Add Account" button) depends on this exact name/signature.

- [ ] **Step 1: Replace the `cuxAccountSwitcher` property and add `accountCapture`**

In `Sources/ClaudeStatusBar/AppState.swift`, replace:

```swift
    private let cuxAccountSwitcher = CuxAccountSwitcher()
```

with:

```swift
    private let nativeAccountSwitcher = NativeAccountSwitcher()
    private let accountCapture: AccountCapture
```

Since `accountCapture` needs `paths.root` (not available until `init` runs), initialize it in `init(paths:settings:)` — add this line after `self.paths = paths` is set (immediately before or after the existing `self.usageStore = ...` line):

```swift
        self.accountCapture = AccountCapture(storeFile: paths.root.appendingPathComponent("native-accounts.json"))
```

Add a new property for the capture-polling ticker, alongside the existing `reaggregateTask`/`pollTask`/`updateCheckTask` properties:

```swift
    private var captureTask: Task<Void, Never>?
```

- [ ] **Step 2: Add `resolveAccounts()` and replace the three `AccountDiscovery.discover(...)` call sites**

Add this new private method to `AppState` (near `refreshUsageNow()`):

```swift
    private func resolveAccounts() -> [Account] {
        let nativeFile = paths.root.appendingPathComponent("native-accounts.json")
        CuxStateImporter.importIfNeeded(cuxRoot: cuxRoot, nativeStateFile: nativeFile)
        let nativeState = NativeAccountStore.load(file: nativeFile)
        guard !nativeState.accounts.isEmpty else {
            return AccountDiscovery.discover(cuxRoot: cuxRoot, credentialsFile: credentialsFile)
        }
        let flaggedIds = nativeState.accounts.filter(\.needsRelogin).map(\.id)
        usageStore.seedNeedsRelogin(flaggedIds)
        return NativeAccountStore.toAccounts(nativeState)
    }
```

Replace all three existing call sites — `accounts = AccountDiscovery.discover(cuxRoot: cuxRoot, credentialsFile: credentialsFile)` in `start()`, `refreshUsageNow()`, and `pollOnce()` — with:

```swift
        accounts = resolveAccounts()
```

Leave `cuxRefresher.refreshIfNeeded(accounts:)` and the `CuxUsageCache` join inside `usageInputs(_:)` completely untouched — they only matter for accounts still on the cux-managed path (pre-migration), are harmless no-ops/misses for native accounts, and touching them is explicitly out of scope for this feature (usage fetching's cux-independence was already handled in earlier work).

- [ ] **Step 3: Update `switchAccount(_:)`**

Replace:

```swift
    func switchAccount(_ account: Account) async {
        guard let slot = account.slot else { return }
        let succeeded = await cuxAccountSwitcher.switchTo(slot: slot)
        switchFailedAccountId = succeeded ? nil : account.id
        await refreshUsageNow()
    }
```

with:

```swift
    /// Switches the active account via NativeAccountSwitcher, then
    /// re-resolves accounts and refreshes usage so isActive/usage bars
    /// reflect the switch immediately. No-op for the plain default account
    /// (slot == nil) — it has nothing to switch to, and the UI never shows
    /// a Switch button for it (see AccountsSection.swift).
    func switchAccount(_ account: Account) async {
        guard account.slot != nil else { return }
        let succeeded = await nativeAccountSwitcher.switchTo(account: account)
        switchFailedAccountId = succeeded ? nil : account.id
        await refreshUsageNow()
    }
```

- [ ] **Step 4: Add `beginAddAccount()` and fold capture-checking into `recheckReloginAccounts()`**

Add this new method:

```swift
    /// Snapshots the currently-live credentials as the pre-login baseline,
    /// then launches `claude /login` in Terminal. The resulting new login
    /// is picked up by `recheckReloginAccounts()` (popover-open + the
    /// ~60s captureTask ticker started in `start()`).
    func beginAddAccount() async {
        await accountCapture.beginCapture()
        TerminalLauncher.run("claude /login")
    }
```

Update `recheckReloginAccounts()`:

```swift
    func recheckReloginAccounts() async {
        if case .captured = await accountCapture.checkForNewLogin() {
            await refreshUsageNow()
        }
        let flagged = accounts.filter { usageStore.states[$0.id]?.needsRelogin == true }
        guard !flagged.isEmpty else { return }
        await usageStore.refresh(accounts: usageInputs(flagged))
    }
```

(`PopoverView.swift`'s existing `.task { await appState.recheckReloginAccounts() }` call site at popover-open needs no change — it already covers the capture check.)

- [ ] **Step 5: Start the ~60s capture-polling ticker in `start()`**

In `start()`, alongside the existing ticker `Task`s (`reaggregateTask`, `pollTask`, `updateCheckTask`), add:

```swift
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.recheckReloginAccounts()
            }
        }
```

- [ ] **Step 6: Build and smoke-test**

Run: `make build`
Expected: builds cleanly with no references to `CuxAccountSwitcher` remaining in `AppState.swift`.

Manual smoke test (since this file has no dedicated tests): `make app`, launch `dist/ClaudeStatusBar.app`, open the popover, confirm the account list still renders (falls back to the plain default account if no cux/native state exists yet) and no crash occurs.

- [ ] **Step 7: Commit**

```bash
git add Sources/ClaudeStatusBar/AppState.swift
git commit -m "feat(app): wire AppState to NativeAccountSwitcher, AccountCapture, and native account resolution"
```

---

### Task 11: `AccountsSection` — Add Account button, updated switch-failure text

**Files:**
- Modify: `Sources/ClaudeStatusBar/AccountsSection.swift`

**No dedicated test file** — same rationale as Task 10; verify with `make build` and a manual smoke test.

**Interfaces:**
- Consumes: `AppState.beginAddAccount() async` (Task 10).

- [ ] **Step 1: Add an `onAddAccount` closure param and an "Add Account" button**

In `Sources/ClaudeStatusBar/AccountsSection.swift`, add a new property to `AccountsSection`:

```swift
    let onAddAccount: () -> Void
```

Add an "Add Account" button at the bottom of `AccountsSection`'s `body`, after the existing `if accounts.isEmpty { ... } else { ForEach(...) }` block:

```swift
            Button("Add Account") { onAddAccount() }
                .controlSize(.small)
```

So the full `body` reads:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accounts").font(.caption).foregroundStyle(.secondary)
            if accounts.isEmpty {
                Text(CuxAvailability.isInstalled()
                     ? "No Claude account found — log in with cux or Claude Code"
                     : "No Claude account found — log in with claude /login")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { account in
                    AccountRow(account: account, state: states[account.id],
                               yellowAt: yellowAt, redAt: redAt, normalColor: normalColor,
                               yellowColor: yellowColor, redColor: redColor, now: now,
                               showActiveBadge: accounts.count > 1,
                               switchFailed: switchFailedAccountId == account.id,
                               onSwitch: onSwitch)
                }
            }
            Button("Add Account") { onAddAccount() }
                .controlSize(.small)
        }
    }
```

- [ ] **Step 2: Update the switch-failed message text**

Replace the cux-specific failure text:

```swift
            if switchFailed {
                Text("Switch failed — is cux installed and working?")
                    .font(.caption2).foregroundStyle(.orange)
            }
```

with:

```swift
            if switchFailed {
                Text("Switch failed — check native-switch.log")
                    .font(.caption2).foregroundStyle(.orange)
            }
```

- [ ] **Step 3: Update `AccountsSection`'s call site**

Find where `AccountsSection(...)` is constructed (in the parent popover view) and add the new `onAddAccount:` argument, wired to `AppState.beginAddAccount()`:

```swift
onAddAccount: { Task { await appState.beginAddAccount() } }
```

- [ ] **Step 4: Build and smoke-test**

Run: `make build`
Expected: builds cleanly.

Manual smoke test: `make app`, launch the app, open the popover, confirm an "Add Account" button appears below the account list and the switch-failure text (if triggerable) now reads "Switch failed — check native-switch.log".

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/AccountsSection.swift
git commit -m "feat(ui): add Add Account button, update switch-failure message for native switching"
```

---

### Task 12: Remove `CuxAccountSwitcher`

**Files:**
- Delete: `Sources/StatusBarCore/Accounts/CuxAccountSwitcher.swift`
- Delete: `Tests/StatusBarCoreTests/CuxAccountSwitcherTests.swift`

**Why last:** by this point nothing references `CuxAccountSwitcher` — `AppState.swift` was switched over to `NativeAccountSwitcher` in Task 10. Deleting it last means every earlier task can still build/test against a repo where the old type exists, minimizing risk of an intermediate broken state if tasks are reviewed/landed one at a time.

**Interfaces:**
- Consumes: nothing (deletion only).
- Produces: nothing — this task only removes dead code.

- [ ] **Step 1: Confirm no remaining references**

Run: `grep -rn "CuxAccountSwitcher" Sources/ Tests/`
Expected: no output (Task 10 already replaced the only production call site; the only remaining hits should be the two files this task deletes).

- [ ] **Step 2: Delete the files**

```bash
git rm Sources/StatusBarCore/Accounts/CuxAccountSwitcher.swift Tests/StatusBarCoreTests/CuxAccountSwitcherTests.swift
```

- [ ] **Step 3: Build and run the full test suite**

Run: `make build && make test`
Expected: builds cleanly, full suite passes with no reference errors.

- [ ] **Step 4: Commit**

```bash
git commit -m "chore(accounts): remove CuxAccountSwitcher, fully replaced by NativeAccountSwitcher"
```

---

## Self-Review

**1. Spec coverage:**
- `NativeAccountStore`, `AccountCredentialVault`, `LiveCredentialWriter`, `NativeAccountSwitcher`, `AccountCapture`, `CuxStateImporter` — Tasks 2–8. ✅
- "Reusing `Account.slot`" semantics — implemented via `resolveAccounts()`'s native-vs-fallback branching (Task 10) and `NativeAccountStore.toAccount` always setting a non-nil `slot`. ✅
- Add account via capture-after-login — Tasks 8, 10, 11 (`beginAddAccount`, `checkForNewLogin`, "Add Account" button). ✅
- Switch account via Keychain Services directly — Task 5. ✅
- First-run migration — Task 7, wired into `resolveAccounts()` in Task 10. ✅
- Error handling & rollback (fail-safe-first ordering, `native-switch.log`, harmless no-op for already-active) — Task 5. ✅
- Security considerations (tighter vault ACL, explicit trust list for the live item, claude-path resolution with app-only fallback) — Tasks 3, 4. ✅
- Testing — one file per new source file, injectable closures throughout, the exact test lists from the spec (full success / backup-read failure / backup-current-live failure / live-write failure / oauthAccount-write failure with rollback / state-save failure) — Task 5. ✅
- Out-of-scope items (native OAuth client, manual account editing, real-time capture, cleaning up cux's own Keychain items) — none implemented. ✅
- Two gaps not in the original spec's Modified-files list, both now documented and included: `UsageStore.swift` (Task 6) and `AccountDiscovery.swift`'s new `emailAddress(from:)` helper (Task 1). ✅

**2. Placeholder scan:** No "TBD"/"TODO"/"handle appropriately" language anywhere above; every step shows complete code. `CuxStateImporter`'s backup-label format is flagged as an explicit, bounded assumption (not a placeholder) with a concrete verification command and a documented safe-degradation path.

**3. Type consistency:** Traced every cross-task name: `NativeAccount`/`NativeAccountState` (Task 2) match field-for-field in Tasks 5, 7, 8, 10. `CredentialBackup` (Task 3) matches in Tasks 5, 7, 8. `LiveCredentialWriter`'s four public members (Task 4) match their call sites in Task 5. `NativeAccountSwitcher.switchTo(account:)` and `AccountCapture.beginCapture()`/`.checkForNewLogin()` match their `AppState` call sites in Task 10. `UsageStore.seedNeedsRelogin(_:)` (Task 6) matches its call in Task 10's `resolveAccounts()`. The bare-function-reference-vs-default-parameters gotcha is called out explicitly in Task 5 and consistently avoided (wrapped closures) in every task that wires one component's defaulted static function into another's injectable closure.

---

**Plan complete and saved to `docs/superpowers/plans/2026-07-16-native-account-switching.md`.** Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
