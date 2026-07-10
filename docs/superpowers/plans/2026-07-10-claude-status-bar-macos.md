# Claude Status Bar for macOS — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu bar app showing Claude usage (5h/7d, multi-account via `~/.cux`) and live Claude Code session activity (via hooks), per the approved spec `docs/superpowers/specs/2026-07-10-claude-status-bar-macos-design.md`.

**Architecture:** One SwiftPM package, three targets: `StatusBarCore` (library — all logic, fully unit-tested, zero UI imports), `ClaudeStatusBar` (SwiftUI `MenuBarExtra` app), `ClaudeStatusHook` (CLI invoked by Claude Code hooks; product name `claude-status-hook`). The `.app` bundle is assembled by `scripts/make-app.sh` (no Xcode project).

**Tech Stack:** Swift (tools 6.0, language mode v5), SwiftUI `MenuBarExtra`, Swift Testing (`import Testing`), URLSession, DispatchSource file watching, UserDefaults, SMAppService, GitHub Actions (macos-15).

## Global Constraints

- Minimum macOS **14** (Sonoma). `platforms: [.macOS(.v14)]`.
- **SwiftPM only** — the dev machine has Command Line Tools only (Swift 6.2, no Xcode, no xcodegen). Never emit an `.xcodeproj`. Everything must work via `swift build` / `swift test` / `make`.
- swift-tools-version **6.0** with `.swiftLanguageMode(.v5)` on **every** target (avoids strict-concurrency churn).
- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`) — not XCTest.
- **Clean-room**: the KDE repo (vntrungld/claude-status-bar-kde) has NO license — never copy code, strings, or its verbs list from it. Only the Clawd artwork is reusable (MIT, from marciogranzotto/clawd-tank, attribution required).
- `claude-status-hook` must **always exit 0** and never write to stdout/stderr on error — it must never block Claude Code.
- **Never read, log, or copy real credentials.** Tests use fixture files in temp dirs only; never touch the real `~/.cux` or `~/.claude` in tests. Tokens live only in local variables at fetch time.
- Usage endpoint facts (verified): `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <token>` and `User-Agent: claude-code/2.1.197`; response `{"five_hour":{"utilization":N},"seven_day":{"utilization":N}}`, utilization 0–100 (int or float — accept both); `resets_at` per window is OPTIONAL (may be absent).
- TDD: each task = failing test → run → implement → run → **commit**. Commit subjects ≤72 chars, imperative, English.
- Work on a side branch; PR into `main`; never push `main` directly.
- All files, comments, commits in **English**.

## File structure (end state)

```
Package.swift
Makefile                              # build / test / hook-test / app / dmg
LICENSE                               # MIT, Copyright (c) 2026 juzser
LICENSE.clawd-tank                    # MIT, artwork attribution (Task 14)
README.md
.gitignore
.github/workflows/ci.yml
Sources/StatusBarCore/
  StatusBarCore.swift                 # version constant
  AppPaths.swift  AtomicFile.swift  ISO8601.swift
  Usage/UsageModels.swift             # UsageWindow, UsageSnapshot, UsageLevel
  Usage/UsageClient.swift             # UsageFetching, UsageError, UsageClient
  Usage/UsageStore.swift              # AccountUsageState, UsageStore
  Accounts/AccountDiscovery.swift     # Account, AccountDiscovery
  Sessions/HookEvent.swift            # HookEvent, ToolLabels
  Sessions/SessionRecord.swift        # SessionState, SessionRecord, SessionReducer
  Sessions/SessionAggregator.swift
  Hooks/HookSettingsMerger.swift
  Hooks/HookInstaller.swift
  Display/MenuBarText.swift           # DisplayStyle, IconState, ElapsedFormat, MenuBarLabelModel, MenuBarText
  Display/ThinkingVerbs.swift
  SettingsStore.swift                 # (Task 13)
Sources/ClaudeStatusBar/
  ClaudeStatusBarApp.swift  AppState.swift  DirectoryWatcher.swift
  Views/MenuBarLabel.swift  Views/PopoverView.swift  Views/SettingsView.swift
  Resources/clawd/*.png               # 7 icons (Task 14)
Sources/ClaudeStatusHook/main.swift
Tests/StatusBarCoreTests/*.swift
scripts/make-app.sh  scripts/hook-integration-test.sh
```

---

### Task 1: Package scaffold

**Files:**
- Create: `Package.swift`, `Sources/StatusBarCore/StatusBarCore.swift`, `Sources/ClaudeStatusBar/ClaudeStatusBarApp.swift`, `Sources/ClaudeStatusBar/Resources/clawd/.gitkeep` (empty file), `Sources/ClaudeStatusHook/main.swift`, `Tests/StatusBarCoreTests/PackageTests.swift`, `.gitignore`, `Makefile`, `LICENSE`, `README.md`, `.github/workflows/ci.yml`

**Interfaces:**
- Produces: the three targets every later task builds on; `StatusBarCoreInfo.version: String`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "claude-status-bar-macos",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeStatusBar", targets: ["ClaudeStatusBar"]),
        .executable(name: "claude-status-hook", targets: ["ClaudeStatusHook"]),
        .library(name: "StatusBarCore", targets: ["StatusBarCore"]),
    ],
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
            dependencies: ["StatusBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
```

Note: SwiftPM module names cannot contain hyphens — the target is `ClaudeStatusHook`; the hyphenated name lives on the *product* only.

- [ ] **Step 2: Write stub sources**

`Sources/StatusBarCore/StatusBarCore.swift`:

```swift
public enum StatusBarCoreInfo {
    public static let version = "0.1.0"
}
```

`Sources/ClaudeStatusBar/ClaudeStatusBarApp.swift`:

```swift
import SwiftUI

@main
struct ClaudeStatusBarApp: App {
    var body: some Scene {
        MenuBarExtra("Claude", systemImage: "pawprint") {
            Text("Claude Status Bar")
        }
    }
}
```

`Sources/ClaudeStatusBar/Resources/clawd/.gitkeep`: empty file (keeps the resource dir so `.copy("Resources/clawd")` resolves).

`Sources/ClaudeStatusHook/main.swift`:

```swift
import Foundation

exit(0)
```

- [ ] **Step 3: Write the placeholder test**

`Tests/StatusBarCoreTests/PackageTests.swift`:

```swift
import Testing
@testable import StatusBarCore

@Test func versionIsSet() {
    #expect(StatusBarCoreInfo.version == "0.1.0")
}
```

- [ ] **Step 4: Run tests**

Run: `swift test`
Expected: PASS — output ends with `Test run with 1 test passed`.

- [ ] **Step 5: Write support files**

`.gitignore`:

```
.build/
dist/
.DS_Store
*.xcodeproj
```

`Makefile` — **indent recipes with real tabs, not spaces**:

```makefile
.PHONY: build test

build:
	swift build

test:
	swift test
```

`LICENSE`: standard MIT text with the line `Copyright (c) 2026 juzser`.

`README.md`:

```markdown
# claude-status-bar-macos

macOS menu bar app showing Claude usage (5h/7d, multi-account) and live
Claude Code session activity. Work in progress — see
`docs/superpowers/specs/2026-07-10-claude-status-bar-macos-design.md`.

## Development

    make build
    make test
```

`.github/workflows/ci.yml`:

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [main]
jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - run: swift test
```

- [ ] **Step 6: Verify via make**

Run: `make build && make test`
Expected: both succeed (`Build complete!`, `Test run with 1 test passed`).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: scaffold SwiftPM package with three targets"
```

---

### Task 2: AppPaths, AtomicFile, ISO8601

**Files:**
- Create: `Sources/StatusBarCore/AppPaths.swift`, `Sources/StatusBarCore/AtomicFile.swift`, `Sources/StatusBarCore/ISO8601.swift`
- Test: `Tests/StatusBarCoreTests/FoundationTests.swift`

**Interfaces:**
- Produces:
  - `AppPaths(root: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment)`; `.root: URL`, `.sessionsDir: URL`, `.usageCacheFile: URL`, `.ensureDirs() throws`. Root resolution order: explicit arg > env `CLAUDE_STATUS_BAR_HOME` > `~/Library/Application Support/ClaudeStatusBar`.
  - `AtomicFile.write(_ data: Data, to url: URL) throws` — temp file + POSIX `rename`, creates parent dirs.
  - `ISO8601.parse(_ s: String) -> Date?` (accepts fractional and plain), `ISO8601.string(from: Date) -> String`.

- [ ] **Step 1: Write the failing tests**

`Tests/StatusBarCoreTests/FoundationTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

@Suite struct AppPathsTests {
    @Test func explicitRootWins() {
        let root = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let paths = AppPaths(root: root, environment: ["CLAUDE_STATUS_BAR_HOME": "/elsewhere"])
        #expect(paths.root == root)
    }

    @Test func envOverridesDefault() {
        let paths = AppPaths(environment: ["CLAUDE_STATUS_BAR_HOME": "/tmp/env-home"])
        #expect(paths.root.path == "/tmp/env-home")
    }

    @Test func defaultIsUnderApplicationSupport() {
        let paths = AppPaths(environment: [:])
        #expect(paths.root.path.hasSuffix("Application Support/ClaudeStatusBar"))
    }

    @Test func derivedPaths() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/x", isDirectory: true))
        #expect(paths.sessionsDir.path == "/tmp/x/sessions")
        #expect(paths.usageCacheFile.path == "/tmp/x/usage-cache.json")
    }

    @Test func ensureDirsCreatesSessionsDir() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = AppPaths(root: tmp)
        try paths.ensureDirs()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.sessionsDir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }
}

@Suite struct AtomicFileTests {
    @Test func writesCreatesDirsAndOverwrites() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("atomic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("nested").appendingPathComponent("out.json")
        try AtomicFile.write(Data("one".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one")
        try AtomicFile.write(Data("two".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")
        let dir = file.deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["out.json"])  // no temp files left behind
    }
}

@Suite struct ISO8601Tests {
    @Test func parsesPlainAndFractional() {
        #expect(ISO8601.parse("2026-07-10T03:00:00Z") != nil)
        #expect(ISO8601.parse("2026-07-10T03:00:00.123Z") != nil)
        #expect(ISO8601.parse("garbage") == nil)
    }

    @Test func roundTrips() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ISO8601.parse(ISO8601.string(from: date)) == date)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: COMPILE ERROR — `cannot find 'AppPaths' in scope` (and same for `AtomicFile`, `ISO8601`).

- [ ] **Step 3: Implement**

`Sources/StatusBarCore/AppPaths.swift`:

```swift
import Foundation

public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let root {
            self.root = root
        } else if let env = environment["CLAUDE_STATUS_BAR_HOME"], !env.isEmpty {
            self.root = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            self.root = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ClaudeStatusBar", isDirectory: true)
        }
    }

    public var sessionsDir: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    public var usageCacheFile: URL {
        root.appendingPathComponent("usage-cache.json")
    }

    public func ensureDirs() throws {
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }
}
```

`Sources/StatusBarCore/AtomicFile.swift`:

```swift
import Foundation

public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
```

`Sources/StatusBarCore/ISO8601.swift`:

```swift
import Foundation

public enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }

    public static func string(from date: Date) -> String {
        plain.string(from: date)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — `Test run with 9 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore Tests
git commit -m "feat: add AppPaths, AtomicFile, ISO8601 helpers"
```

---

### Task 3: Usage models and response parsing

**Files:**
- Create: `Sources/StatusBarCore/Usage/UsageModels.swift`
- Test: `Tests/StatusBarCoreTests/UsageModelTests.swift`

**Interfaces:**
- Produces:
  - `UsageWindow: Codable, Equatable, Sendable` — `utilization: Double`, `resetsAt: Date?`; `init(utilization: Double, resetsAt: Date? = nil)`.
  - `UsageSnapshot: Codable, Equatable, Sendable` — `fiveHour: UsageWindow?`, `sevenDay: UsageWindow?`, `fetchedAt: Date`; `init(fiveHour:sevenDay:fetchedAt:)`; `static func parse(_ data: Data, fetchedAt: Date) -> UsageSnapshot?`.
  - `UsageLevel: String enum` — `.green/.yellow/.red`; `static func level(for utilization: Double, yellowAt: Double = 50, redAt: Double = 80) -> UsageLevel`.

- [ ] **Step 1: Write the failing tests**

`Tests/StatusBarCoreTests/UsageModelTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

@Suite struct UsageParsingTests {
    @Test func parsesFullResponse() throws {
        let json = """
        {"five_hour":{"utilization":70.5,"resets_at":"2026-07-10T05:00:00Z"},
         "seven_day":{"utilization":29}}
        """
        let snap = try #require(UsageSnapshot.parse(Data(json.utf8),
                                                    fetchedAt: Date(timeIntervalSince1970: 0)))
        #expect(snap.fiveHour?.utilization == 70.5)
        #expect(snap.fiveHour?.resetsAt == ISO8601.parse("2026-07-10T05:00:00Z"))
        #expect(snap.sevenDay?.utilization == 29)
        #expect(snap.sevenDay?.resetsAt == nil)
        #expect(snap.fetchedAt == Date(timeIntervalSince1970: 0))
    }

    @Test func integerUtilizationAccepted() throws {
        let json = #"{"five_hour":{"utilization":42}}"#
        let snap = try #require(UsageSnapshot.parse(Data(json.utf8), fetchedAt: .now))
        #expect(snap.fiveHour?.utilization == 42)
        #expect(snap.sevenDay == nil)
    }

    @Test func unknownFieldsIgnored() throws {
        let json = #"{"five_hour":{"utilization":1,"extra":true},"other_window":{}}"#
        let snap = try #require(UsageSnapshot.parse(Data(json.utf8), fetchedAt: .now))
        #expect(snap.fiveHour?.utilization == 1)
    }

    @Test func garbageReturnsNil() {
        #expect(UsageSnapshot.parse(Data("not json".utf8), fetchedAt: .now) == nil)
        #expect(UsageSnapshot.parse(Data("{}".utf8), fetchedAt: .now) == nil)
        #expect(UsageSnapshot.parse(Data(#"{"five_hour":{"utilization":"high"}}"#.utf8),
                                    fetchedAt: .now) == nil)
    }

    @Test func codableRoundTrip() throws {
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 70, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
            sevenDay: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_799_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UsageSnapshot.self, from: try encoder.encode(snap))
        #expect(decoded == snap)
    }
}

@Suite struct UsageLevelTests {
    @Test func defaultThresholds() {
        #expect(UsageLevel.level(for: 0) == .green)
        #expect(UsageLevel.level(for: 49.9) == .green)
        #expect(UsageLevel.level(for: 50) == .yellow)
        #expect(UsageLevel.level(for: 79.9) == .yellow)
        #expect(UsageLevel.level(for: 80) == .red)
        #expect(UsageLevel.level(for: 100) == .red)
    }

    @Test func customThresholds() {
        #expect(UsageLevel.level(for: 60, yellowAt: 40, redAt: 70) == .yellow)
        #expect(UsageLevel.level(for: 75, yellowAt: 40, redAt: 70) == .red)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UsageParsingTests`
Expected: COMPILE ERROR — `cannot find 'UsageSnapshot' in scope`.

- [ ] **Step 3: Implement**

`Sources/StatusBarCore/Usage/UsageModels.swift`:

```swift
import Foundation

public struct UsageWindow: Codable, Equatable, Sendable {
    public let utilization: Double
    public let resetsAt: Date?

    public init(utilization: Double, resetsAt: Date? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let fetchedAt: Date

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
    }

    /// Tolerant parser for the /api/oauth/usage response. Unknown fields are
    /// ignored; a response with neither window is treated as malformed.
    public static func parse(_ data: Data, fetchedAt: Date) -> UsageSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let five = window(from: obj["five_hour"])
        let seven = window(from: obj["seven_day"])
        if five == nil && seven == nil { return nil }
        return UsageSnapshot(fiveHour: five, sevenDay: seven, fetchedAt: fetchedAt)
    }

    private static func window(from any: Any?) -> UsageWindow? {
        guard let dict = any as? [String: Any] else { return nil }
        guard let number = dict["utilization"] as? NSNumber,
              !(number is NSString) else { return nil }
        let resets = (dict["resets_at"] as? String).flatMap(ISO8601.parse)
        return UsageWindow(utilization: number.doubleValue, resetsAt: resets)
    }
}

public enum UsageLevel: String, Equatable, Sendable {
    case green, yellow, red

    public static func level(for utilization: Double,
                             yellowAt: Double = 50,
                             redAt: Double = 80) -> UsageLevel {
        if utilization >= redAt { return .red }
        if utilization >= yellowAt { return .yellow }
        return .green
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — `Test run with 16 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Usage Tests
git commit -m "feat: parse usage API response tolerantly with level thresholds"
```

---

### Task 4: Account discovery (cux + credentials fallback)

**Files:**
- Create: `Sources/StatusBarCore/Accounts/AccountDiscovery.swift`
- Test: `Tests/StatusBarCoreTests/AccountDiscoveryTests.swift`

**Interfaces:**
- Produces:
  - `Account: Equatable, Sendable, Identifiable` — `id: String` (`"slot-<n>"` for cux, `"default"` for fallback), `alias: String?`, `email: String?`, `slot: Int?`, `isActive: Bool`, `oauthURL: URL` (the file holding the token).
  - `AccountDiscovery.discover(cuxRoot: URL, credentialsFile: URL) -> [Account]` — cux accounts sorted by slot; falls back to a single `"default"` account when `~/.cux` is unusable; `[]` when neither source exists.
  - `AccountDiscovery.accessToken(from data: Data) -> String?` — accepts both `{"claudeAiOauth":{"accessToken":…}}` and flat `{"accessToken":…}`.

**Security note:** tests build fixture trees with FAKE tokens under `FileManager.default.temporaryDirectory`. Never point tests at the real `~/.cux` or `~/.claude`, and never print token values.

- [ ] **Step 1: Write the failing tests**

`Tests/StatusBarCoreTests/AccountDiscoveryTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

private func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acct-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Fixture ~/.cux tree with two accounts (zero-padded dir for slot 1,
/// unpadded for slot 2 — discovery must accept both namings).
private func makeCuxFixture(in root: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("accounts/01-a@x.com"),
                           withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("accounts/2-b@y.com"),
                           withIntermediateDirectories: true)
    let state = """
    {"activeSlot":1,"accounts":{
      "1":{"slot":1,"email":"a@x.com","alias":"ser","uuid":"u1","addedAt":"2026-01-01T00:00:00Z"},
      "2":{"slot":2,"email":"b@y.com","alias":"oe"}}}
    """
    try Data(state.utf8).write(to: root.appendingPathComponent("state.json"))
    try Data(#"{"claudeAiOauth":{"accessToken":"fake-token-1"}}"#.utf8)
        .write(to: root.appendingPathComponent("accounts/01-a@x.com/oauth.json"))
    try Data(#"{"accessToken":"fake-token-2"}"#.utf8)
        .write(to: root.appendingPathComponent("accounts/2-b@y.com/oauth.json"))
}

@Suite struct AccountDiscoveryTests {
    @Test func discoversCuxAccountsSortedBySlot() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cux = tmp.appendingPathComponent("cux", isDirectory: true)
        try makeCuxFixture(in: cux)
        let accounts = AccountDiscovery.discover(
            cuxRoot: cux, credentialsFile: tmp.appendingPathComponent("none.json"))
        #expect(accounts.count == 2)
        #expect(accounts[0].id == "slot-1")
        #expect(accounts[0].alias == "ser")
        #expect(accounts[0].email == "a@x.com")
        #expect(accounts[0].isActive)
        #expect(accounts[0].oauthURL.path.hasSuffix("accounts/01-a@x.com/oauth.json"))
        #expect(accounts[1].id == "slot-2")
        #expect(!accounts[1].isActive)
        #expect(accounts[1].oauthURL.path.hasSuffix("accounts/2-b@y.com/oauth.json"))
    }

    @Test func skipsAccountWithoutTokenFile() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cux = tmp.appendingPathComponent("cux", isDirectory: true)
        try makeCuxFixture(in: cux)
        try FileManager.default.removeItem(
            at: cux.appendingPathComponent("accounts/2-b@y.com/oauth.json"))
        let accounts = AccountDiscovery.discover(
            cuxRoot: cux, credentialsFile: tmp.appendingPathComponent("none.json"))
        #expect(accounts.map(\.id) == ["slot-1"])
    }

    @Test func fallsBackToCredentialsFile() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let creds = tmp.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"fake"}}"#.utf8).write(to: creds)
        let accounts = AccountDiscovery.discover(
            cuxRoot: tmp.appendingPathComponent("no-cux"), credentialsFile: creds)
        #expect(accounts.count == 1)
        #expect(accounts[0].id == "default")
        #expect(accounts[0].isActive)
        #expect(accounts[0].slot == nil)
        #expect(accounts[0].oauthURL == creds)
    }

    @Test func emptyWhenNoSourceExists() {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let accounts = AccountDiscovery.discover(
            cuxRoot: tmp.appendingPathComponent("no-cux"),
            credentialsFile: tmp.appendingPathComponent("none.json"))
        #expect(accounts.isEmpty)
    }

    @Test func malformedStateFallsBackToCredentials() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cux = tmp.appendingPathComponent("cux", isDirectory: true)
        try FileManager.default.createDirectory(at: cux, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: cux.appendingPathComponent("state.json"))
        let creds = tmp.appendingPathComponent(".credentials.json")
        try Data(#"{"accessToken":"fake"}"#.utf8).write(to: creds)
        let accounts = AccountDiscovery.discover(cuxRoot: cux, credentialsFile: creds)
        #expect(accounts.map(\.id) == ["default"])
    }
}

@Suite struct AccessTokenTests {
    @Test func nestedShape() {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"fake-abc"}}"#.utf8)
        #expect(AccountDiscovery.accessToken(from: data) == "fake-abc")
    }

    @Test func flatShape() {
        let data = Data(#"{"accessToken":"fake-xyz"}"#.utf8)
        #expect(AccountDiscovery.accessToken(from: data) == "fake-xyz")
    }

    @Test func malformedReturnsNil() {
        #expect(AccountDiscovery.accessToken(from: Data("nope".utf8)) == nil)
        #expect(AccountDiscovery.accessToken(from: Data("{}".utf8)) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AccountDiscoveryTests`
Expected: COMPILE ERROR — `cannot find 'AccountDiscovery' in scope`.

- [ ] **Step 3: Implement**

`Sources/StatusBarCore/Accounts/AccountDiscovery.swift`:

```swift
import Foundation

public struct Account: Equatable, Sendable, Identifiable {
    public let id: String
    public let alias: String?
    public let email: String?
    public let slot: Int?
    public let isActive: Bool
    public let oauthURL: URL

    public init(id: String, alias: String?, email: String?, slot: Int?,
                isActive: Bool, oauthURL: URL) {
        self.id = id
        self.alias = alias
        self.email = email
        self.slot = slot
        self.isActive = isActive
        self.oauthURL = oauthURL
    }
}

public enum AccountDiscovery {
    private struct CuxState: Decodable {
        struct CuxAccount: Decodable {
            let slot: Int
            let email: String
            let alias: String?
        }
        let activeSlot: Int?
        let accounts: [String: CuxAccount]
    }

    public static func discover(cuxRoot: URL, credentialsFile: URL) -> [Account] {
        if let accounts = discoverCux(root: cuxRoot), !accounts.isEmpty {
            return accounts
        }
        if FileManager.default.fileExists(atPath: credentialsFile.path) {
            return [Account(id: "default", alias: nil, email: nil, slot: nil,
                            isActive: true, oauthURL: credentialsFile)]
        }
        return []
    }

    /// Reads only cux metadata (slots, emails, aliases) — never token contents.
    private static func discoverCux(root: URL) -> [Account]? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
              let state = try? JSONDecoder().decode(CuxState.self, from: data) else {
            return nil
        }
        let accountsDir = root.appendingPathComponent("accounts", isDirectory: true)
        let entries = (try? fm.contentsOfDirectory(atPath: accountsDir.path)) ?? []
        return state.accounts.values
            .sorted { $0.slot < $1.slot }
            .compactMap { acct in
                let padded = String(format: "%02d-%@", acct.slot, acct.email)
                let plain = "\(acct.slot)-\(acct.email)"
                guard let dir = entries.first(where: { $0 == padded || $0 == plain }) else {
                    return nil
                }
                let oauth = accountsDir.appendingPathComponent(dir, isDirectory: true)
                    .appendingPathComponent("oauth.json")
                guard fm.fileExists(atPath: oauth.path) else { return nil }
                return Account(id: "slot-\(acct.slot)", alias: acct.alias,
                               email: acct.email, slot: acct.slot,
                               isActive: acct.slot == state.activeSlot,
                               oauthURL: oauth)
            }
    }

    /// Extracts the bearer token from an oauth/credentials JSON file.
    /// Accepts both {"claudeAiOauth":{"accessToken":…}} and {"accessToken":…}.
    public static func accessToken(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let nested = obj["claudeAiOauth"] as? [String: Any],
           let token = nested["accessToken"] as? String {
            return token
        }
        return obj["accessToken"] as? String
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — `Test run with 24 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Accounts Tests
git commit -m "feat: discover accounts from cux state with credentials fallback"
```

---

### Task 5: Hook events, session records, reducer

**Files:**
- Create: `Sources/StatusBarCore/Sessions/HookEvent.swift`, `Sources/StatusBarCore/Sessions/SessionRecord.swift`
- Test: `Tests/StatusBarCoreTests/SessionTests.swift`

**Interfaces:**
- Produces:
  - `HookEvent: Sendable` — `name: String`, `sessionId: String`, `cwd: String?`, `toolName: String?`; `static func parse(eventName: String?, payload: Data) -> HookEvent?`. Payload keys: `hook_event_name`, `session_id`, `cwd`, `tool_name`. `eventName` (argv[1]) wins over the payload key. Rejects (returns nil) a missing/empty `session_id` or one containing characters outside `[A-Za-z0-9_-]` (the id becomes a filename — no path traversal).
  - `ToolLabels.label(for tool: String) -> String`.
  - `SessionState: String, Codable enum` — `.idle/.thinking/.tool/.waiting`.
  - `SessionRecord: Codable, Equatable, Sendable` — `sessionId: String`, `state: SessionState`, `label: String?`, `cwd: String`, `startedAt: Date`, `busySince: Date?`, `updatedAt: Date`; `static func decode(_ data: Data) throws -> SessionRecord`; `func encoded() throws -> Data` (ISO8601 dates, sorted keys, camelCase field names — Task 7's shell test asserts key `sessionId`).
  - `SessionReducer.reduce(_ current: SessionRecord?, event: HookEvent, now: Date) -> SessionRecord?` — nil means "no change to persist".

- [ ] **Step 1: Write the failing tests**

`Tests/StatusBarCoreTests/SessionTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

@Suite struct HookEventTests {
    @Test func parsesPayload() throws {
        let payload = Data(#"{"session_id":"abc-123","cwd":"/tmp/p","tool_name":"Bash","hook_event_name":"PreToolUse"}"#.utf8)
        let event = try #require(HookEvent.parse(eventName: nil, payload: payload))
        #expect(event.name == "PreToolUse")
        #expect(event.sessionId == "abc-123")
        #expect(event.cwd == "/tmp/p")
        #expect(event.toolName == "Bash")
    }

    @Test func argvNameWinsOverPayload() throws {
        let payload = Data(#"{"session_id":"abc","hook_event_name":"Stop"}"#.utf8)
        let event = try #require(HookEvent.parse(eventName: "PreToolUse", payload: payload))
        #expect(event.name == "PreToolUse")
    }

    @Test func rejectsBadInput() {
        #expect(HookEvent.parse(eventName: "Stop", payload: Data("junk".utf8)) == nil)
        #expect(HookEvent.parse(eventName: "Stop", payload: Data("{}".utf8)) == nil)
        // path traversal in session_id must be rejected — it becomes a filename
        let evil = Data(#"{"session_id":"../../etc/passwd"}"#.utf8)
        #expect(HookEvent.parse(eventName: "Stop", payload: evil) == nil)
        // no event name anywhere
        let noName = Data(#"{"session_id":"abc"}"#.utf8)
        #expect(HookEvent.parse(eventName: nil, payload: noName) == nil)
    }
}

@Suite struct ToolLabelsTests {
    @Test func knownTools() {
        #expect(ToolLabels.label(for: "Edit") == "Editing")
        #expect(ToolLabels.label(for: "Write") == "Editing")
        #expect(ToolLabels.label(for: "MultiEdit") == "Editing")
        #expect(ToolLabels.label(for: "NotebookEdit") == "Editing")
        #expect(ToolLabels.label(for: "Bash") == "Running")
        #expect(ToolLabels.label(for: "Read") == "Reading")
        #expect(ToolLabels.label(for: "Grep") == "Searching")
        #expect(ToolLabels.label(for: "Glob") == "Searching")
        #expect(ToolLabels.label(for: "WebFetch") == "Browsing")
        #expect(ToolLabels.label(for: "WebSearch") == "Browsing")
        #expect(ToolLabels.label(for: "Task") == "Delegating")
        #expect(ToolLabels.label(for: "Agent") == "Delegating")
    }

    @Test func unknownToolIsCapitalized() {
        #expect(ToolLabels.label(for: "mcp__thing") == "Mcp__thing")
    }
}

@Suite struct SessionReducerTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 1_060)
    let t2 = Date(timeIntervalSince1970: 1_120)

    private func event(_ name: String, tool: String? = nil) -> HookEvent {
        let toolPart = tool.map { #","tool_name":"\#($0)""# } ?? ""
        let json = #"{"session_id":"s1","cwd":"/tmp/p"\#(toolPart)}"#
        return HookEvent.parse(eventName: name, payload: Data(json.utf8))!
    }

    @Test func sessionStartCreatesIdle() throws {
        let rec = try #require(SessionReducer.reduce(nil, event: event("SessionStart"), now: t0))
        #expect(rec.sessionId == "s1")
        #expect(rec.state == .idle)
        #expect(rec.cwd == "/tmp/p")
        #expect(rec.startedAt == t0)
        #expect(rec.busySince == nil)
    }

    @Test func promptStartsThinkingAndBusyClock() throws {
        let idle = SessionReducer.reduce(nil, event: event("SessionStart"), now: t0)
        let rec = try #require(SessionReducer.reduce(idle, event: event("UserPromptSubmit"), now: t1))
        #expect(rec.state == .thinking)
        #expect(rec.busySince == t1)
        #expect(rec.startedAt == t0)
    }

    @Test func toolUsePreservesBusySinceAndSetsLabel() throws {
        var rec = SessionReducer.reduce(nil, event: event("UserPromptSubmit"), now: t0)
        rec = SessionReducer.reduce(rec, event: event("PreToolUse", tool: "Bash"), now: t1)
        let tool = try #require(rec)
        #expect(tool.state == .tool)
        #expect(tool.label == "Running")
        #expect(tool.busySince == t0)

        let back = try #require(SessionReducer.reduce(tool, event: event("PostToolUse", tool: "Bash"), now: t2))
        #expect(back.state == .thinking)
        #expect(back.label == nil)
        #expect(back.busySince == t0)
    }

    @Test func notificationMeansWaiting() throws {
        let thinking = SessionReducer.reduce(nil, event: event("UserPromptSubmit"), now: t0)
        let rec = try #require(SessionReducer.reduce(thinking, event: event("Notification"), now: t1))
        #expect(rec.state == .waiting)
        #expect(rec.busySince == t0)
    }

    @Test func stopResetsToIdle() throws {
        let thinking = SessionReducer.reduce(nil, event: event("UserPromptSubmit"), now: t0)
        let rec = try #require(SessionReducer.reduce(thinking, event: event("Stop"), now: t1))
        #expect(rec.state == .idle)
        #expect(rec.label == nil)
        #expect(rec.busySince == nil)
        #expect(rec.updatedAt == t1)
    }

    @Test func unknownEventChangesNothing() throws {
        let thinking = SessionReducer.reduce(nil, event: event("UserPromptSubmit"), now: t0)
        let rec = SessionReducer.reduce(thinking, event: event("SomethingNew"), now: t1)
        #expect(rec == thinking)
    }

    @Test func recordRoundTripsDeterministically() throws {
        let rec = try #require(SessionReducer.reduce(nil, event: event("UserPromptSubmit"), now: t0))
        let data = try rec.encoded()
        #expect(try SessionRecord.decode(data) == rec)
        #expect(try rec.encoded() == data)  // sorted keys → stable bytes
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""sessionId":"s1""#))
        #expect(json.contains(#""state":"thinking""#))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionReducerTests`
Expected: COMPILE ERROR — `cannot find 'SessionReducer' in scope`.

- [ ] **Step 3: Implement**

`Sources/StatusBarCore/Sessions/HookEvent.swift`:

```swift
import Foundation

public struct HookEvent: Sendable {
    public let name: String
    public let sessionId: String
    public let cwd: String?
    public let toolName: String?

    private static let allowedIdCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// argv[1] (eventName) wins over the payload's hook_event_name.
    /// Returns nil for malformed payloads or unsafe session ids —
    /// the id is used as a filename, so anything outside [A-Za-z0-9_-] is rejected.
    public static func parse(eventName: String?, payload: Data) -> HookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        guard let name = eventName ?? (obj["hook_event_name"] as? String), !name.isEmpty else {
            return nil
        }
        guard let id = obj["session_id"] as? String, !id.isEmpty,
              id.unicodeScalars.allSatisfy(allowedIdCharacters.contains) else {
            return nil
        }
        return HookEvent(name: name, sessionId: id,
                         cwd: obj["cwd"] as? String,
                         toolName: obj["tool_name"] as? String)
    }
}

public enum ToolLabels {
    public static func label(for tool: String) -> String {
        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing"
        case "Bash": return "Running"
        case "Read": return "Reading"
        case "Grep", "Glob": return "Searching"
        case "WebFetch", "WebSearch": return "Browsing"
        case "Task", "Agent": return "Delegating"
        default: return tool.prefix(1).uppercased() + tool.dropFirst()
        }
    }
}
```

`Sources/StatusBarCore/Sessions/SessionRecord.swift`:

```swift
import Foundation

public enum SessionState: String, Codable, Equatable, Sendable {
    case idle, thinking, tool, waiting
}

public struct SessionRecord: Codable, Equatable, Sendable {
    public var sessionId: String
    public var state: SessionState
    public var label: String?
    public var cwd: String
    public var startedAt: Date
    public var busySince: Date?
    public var updatedAt: Date

    public static func decode(_ data: Data) throws -> SessionRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionRecord.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public enum SessionReducer {
    /// Applies one hook event. Returns nil when the event is unrecognized
    /// and there is no existing record to preserve.
    public static func reduce(_ current: SessionRecord?, event: HookEvent,
                              now: Date) -> SessionRecord? {
        var record = current ?? SessionRecord(
            sessionId: event.sessionId, state: .idle, label: nil,
            cwd: event.cwd ?? "", startedAt: now, busySince: nil, updatedAt: now)
        if let cwd = event.cwd, !cwd.isEmpty { record.cwd = cwd }
        record.updatedAt = now

        switch event.name {
        case "SessionStart":
            record.state = .idle
            record.label = nil
            record.busySince = nil
            record.startedAt = now
        case "UserPromptSubmit":
            record.state = .thinking
            record.label = nil
            record.busySince = record.busySince ?? now
        case "PreToolUse":
            record.state = .tool
            record.label = event.toolName.map(ToolLabels.label(for:)) ?? "Working"
            record.busySince = record.busySince ?? now
        case "PostToolUse":
            record.state = .thinking
            record.label = nil
        case "Notification":
            record.state = .waiting
        case "Stop":
            record.state = .idle
            record.label = nil
            record.busySince = nil
        default:
            return current
        }
        return record
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — `Test run with 34 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Sessions Tests
git commit -m "feat: add hook event parsing and session state reducer"
```

---

### Task 6: Session aggregation

**Files:**
- Create: `Sources/StatusBarCore/Sessions/SessionAggregator.swift`
- Test: `Tests/StatusBarCoreTests/SessionAggregatorTests.swift`

**Interfaces:**
- Consumes: `SessionRecord`, `SessionState` (Task 5); `AtomicFile` (Task 2).
- Produces:
  - `SessionAggregator.staleAfter: TimeInterval` (= 900).
  - `SessionAggregator.loadSessions(from dir: URL, now: Date) -> [SessionRecord]` — reads `*.json`, skips malformed files, drops records whose `updatedAt` is older than 900 s, sorts by `startedAt` ascending.
  - `SessionAggregator.displayState(_ sessions: [SessionRecord]) -> SessionRecord?` — busiest session, priority `waiting > tool > thinking > idle`; ties broken by most recent `updatedAt`.

- [ ] **Step 1: Write the failing tests**

`Tests/StatusBarCoreTests/SessionAggregatorTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

private func record(id: String, state: SessionState, startedAt: Date,
                    updatedAt: Date) -> SessionRecord {
    SessionRecord(sessionId: id, state: state, label: nil, cwd: "/tmp/\(id)",
                  startedAt: startedAt, busySince: nil, updatedAt: updatedAt)
}

@Suite struct SessionAggregatorTests {
    let now = Date(timeIntervalSince1970: 10_000)

    @Test func loadsLiveSessionsSkippingStaleAndMalformed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let live = record(id: "live", state: .thinking,
                          startedAt: now.addingTimeInterval(-500),
                          updatedAt: now.addingTimeInterval(-10))
        let older = record(id: "older", state: .idle,
                           startedAt: now.addingTimeInterval(-800),
                           updatedAt: now.addingTimeInterval(-899))
        let stale = record(id: "stale", state: .tool,
                           startedAt: now.addingTimeInterval(-5_000),
                           updatedAt: now.addingTimeInterval(-901))
        try AtomicFile.write(live.encoded(), to: dir.appendingPathComponent("live.json"))
        try AtomicFile.write(older.encoded(), to: dir.appendingPathComponent("older.json"))
        try AtomicFile.write(stale.encoded(), to: dir.appendingPathComponent("stale.json"))
        try AtomicFile.write(Data("broken".utf8), to: dir.appendingPathComponent("bad.json"))
        try AtomicFile.write(Data("x".utf8), to: dir.appendingPathComponent("notes.txt"))

        let sessions = SessionAggregator.loadSessions(from: dir, now: now)
        #expect(sessions.map(\.sessionId) == ["older", "live"])  // sorted by startedAt
    }

    @Test func missingDirectoryYieldsEmpty() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        #expect(SessionAggregator.loadSessions(from: dir, now: now).isEmpty)
    }

    @Test func displayStatePicksByPriority() {
        let idle = record(id: "a", state: .idle, startedAt: now, updatedAt: now)
        let thinking = record(id: "b", state: .thinking, startedAt: now, updatedAt: now)
        let tool = record(id: "c", state: .tool, startedAt: now, updatedAt: now)
        let waiting = record(id: "d", state: .waiting, startedAt: now, updatedAt: now)
        #expect(SessionAggregator.displayState([idle, thinking])?.sessionId == "b")
        #expect(SessionAggregator.displayState([thinking, tool])?.sessionId == "c")
        #expect(SessionAggregator.displayState([tool, waiting, idle])?.sessionId == "d")
        #expect(SessionAggregator.displayState([]) == nil)
    }

    @Test func tieBrokenByMostRecentUpdate() {
        let older = record(id: "old", state: .tool, startedAt: now,
                           updatedAt: now.addingTimeInterval(-60))
        let newer = record(id: "new", state: .tool, startedAt: now, updatedAt: now)
        #expect(SessionAggregator.displayState([older, newer])?.sessionId == "new")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionAggregatorTests`
Expected: COMPILE ERROR — `cannot find 'SessionAggregator' in scope`.

- [ ] **Step 3: Implement**

`Sources/StatusBarCore/Sessions/SessionAggregator.swift`:

```swift
import Foundation

public enum SessionAggregator {
    /// Sessions not updated within this window are considered dead and hidden.
    public static let staleAfter: TimeInterval = 900

    public static func loadSessions(from dir: URL, now: Date) -> [SessionRecord] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> SessionRecord? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let record = try? SessionRecord.decode(data) else { return nil }
                return now.timeIntervalSince(record.updatedAt) <= staleAfter ? record : nil
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public static func displayState(_ sessions: [SessionRecord]) -> SessionRecord? {
        sessions.max { lhs, rhs in
            if lhs.state.priority != rhs.state.priority {
                return lhs.state.priority < rhs.state.priority
            }
            return lhs.updatedAt < rhs.updatedAt
        }
    }
}

extension SessionState {
    var priority: Int {
        switch self {
        case .waiting: return 3
        case .tool: return 2
        case .thinking: return 1
        case .idle: return 0
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — `Test run with 38 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Sessions Tests
git commit -m "feat: aggregate live sessions with stale filter and priority"
```

---

### Task 7: claude-status-hook CLI + shell integration test

**Files:**
- Modify: `Sources/ClaudeStatusHook/main.swift` (replace the Task 1 stub)
- Create: `scripts/hook-integration-test.sh`
- Modify: `Makefile` (add `hook-test`), `.github/workflows/ci.yml` (run it)

**Interfaces:**
- Consumes: `HookEvent.parse`, `SessionReducer.reduce`, `SessionRecord` (Task 5); `AppPaths` (Task 2); `AtomicFile` (Task 2).
- Produces: the `claude-status-hook` binary. Contract: `claude-status-hook <EventName>` reads the JSON payload from stdin, updates `<AppPaths root>/sessions/<session_id>.json`, and **always exits 0, printing nothing**, even on garbage input. Honors `CLAUDE_STATUS_BAR_HOME` (already built into `AppPaths`). Task 8 installs commands of exactly this shape; Task 13's Settings pane locates the binary next to the app executable.

The CLI has no unit-test target of its own — all logic lives in `StatusBarCore` (already tested). This task's test cycle is the shell integration test against the **built binary**, per the spec's Testing section.

- [ ] **Step 1: Write the failing integration test**

`scripts/hook-integration-test.sh`:

```bash
#!/bin/bash
# Integration test for the claude-status-hook binary.
# Builds nothing itself — expects `swift build` output in .build/debug.
set -u

BIN="${1:-.build/debug/claude-status-hook}"
if [[ ! -x "$BIN" ]]; then
  echo "FAIL: binary not found at $BIN (run: swift build)"; exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_STATUS_BAR_HOME="$TMP"
FAILURES=0

check() { # <desc> <exit_code>
  if [[ "$2" -ne 0 ]]; then echo "FAIL: $1"; FAILURES=$((FAILURES+1)); else echo "ok: $1"; fi
}

# 1. SessionStart creates an idle session file
echo '{"session_id":"it-1","cwd":"/tmp/proj"}' | "$BIN" SessionStart
check "SessionStart exits 0" $?
python3 - "$TMP/sessions/it-1.json" <<'EOF'
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["sessionId"] == "it-1", rec
assert rec["state"] == "idle", rec
assert rec["cwd"] == "/tmp/proj", rec
EOF
check "SessionStart writes idle record" $?

# 2. UserPromptSubmit -> thinking with busySince
echo '{"session_id":"it-1","cwd":"/tmp/proj"}' | "$BIN" UserPromptSubmit
python3 - "$TMP/sessions/it-1.json" <<'EOF'
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["state"] == "thinking", rec
assert rec.get("busySince"), rec
EOF
check "UserPromptSubmit -> thinking + busySince" $?

# 3. PreToolUse -> tool with mapped label
echo '{"session_id":"it-1","cwd":"/tmp/proj","tool_name":"Bash"}' | "$BIN" PreToolUse
python3 - "$TMP/sessions/it-1.json" <<'EOF'
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["state"] == "tool", rec
assert rec["label"] == "Running", rec
EOF
check "PreToolUse -> tool/Running" $?

# 4. Stop -> idle, busySince cleared
echo '{"session_id":"it-1","cwd":"/tmp/proj"}' | "$BIN" Stop
python3 - "$TMP/sessions/it-1.json" <<'EOF'
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["state"] == "idle", rec
assert rec.get("busySince") is None, rec
EOF
check "Stop -> idle, busySince cleared" $?

# 5. Malformed stdin: exit 0, no output, no file
OUT="$(echo 'not json at all' | "$BIN" PreToolUse 2>&1)"
CODE=$?
[[ "$CODE" -eq 0 && -z "$OUT" ]]; check "malformed stdin: silent exit 0" $?
[[ ! -e "$TMP/sessions/not" ]]; check "malformed stdin: no file written" $?

# 6. Missing argv event name: payload hook_event_name used instead
echo '{"session_id":"it-2","cwd":"/x","hook_event_name":"UserPromptSubmit"}' | "$BIN"
check "no argv: exits 0" $?
python3 - "$TMP/sessions/it-2.json" <<'EOF'
import json, sys
assert json.load(open(sys.argv[1]))["state"] == "thinking"
EOF
check "no argv: payload event name used" $?

# 7. Path-traversal session id: exit 0, nothing written outside sessions dir
echo '{"session_id":"../evil"}' | "$BIN" Stop
check "traversal id: exits 0" $?
[[ ! -e "$TMP/evil.json" ]]; check "traversal id: no file escapes sessions dir" $?

if [[ "$FAILURES" -gt 0 ]]; then echo "$FAILURES failure(s)"; exit 1; fi
echo "all hook integration tests passed"
```

Then: `chmod +x scripts/hook-integration-test.sh`

- [ ] **Step 2: Run it to verify it fails**

Run: `swift build && ./scripts/hook-integration-test.sh`
Expected: FAIL — the Task 1 stub exits 0 but writes nothing, so "SessionStart writes idle record" fails (python cannot open the file).

- [ ] **Step 3: Implement the CLI**

Replace `Sources/ClaudeStatusHook/main.swift` with:

```swift
import Foundation
import StatusBarCore

// Claude Code hook entry point: `claude-status-hook <EventName>` with the
// JSON payload on stdin. Must NEVER block or fail Claude Code: every error
// path falls through to a silent exit 0, and nothing is ever printed.
func run() {
    let eventName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    guard let event = HookEvent.parse(eventName: eventName, payload: payload) else { return }

    do {
        let paths = AppPaths()
        try paths.ensureDirs()
        let file = paths.sessionsDir.appendingPathComponent("\(event.sessionId).json")
        let current = (try? Data(contentsOf: file)).flatMap { try? SessionRecord.decode($0) }
        guard let next = SessionReducer.reduce(current, event: event, now: Date()),
              next != current else { return }
        try AtomicFile.write(next.encoded(), to: file)
    } catch {
        // Swallow everything — the hook must not disturb Claude Code.
    }
}

run()
exit(0)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift build && ./scripts/hook-integration-test.sh`
Expected: `all hook integration tests passed`, exit 0. Also run `swift test` — still all green.

- [ ] **Step 5: Wire into Makefile and CI**

Append to `Makefile` (recipe lines use REAL TABS):

```make
hook-test: build
	./scripts/hook-integration-test.sh
```

Add `hook-test` to the `.PHONY` line. In `.github/workflows/ci.yml`, after the `swift test` step add:

```yaml
      - name: Hook integration test
        run: |
          swift build
          ./scripts/hook-integration-test.sh
```

Run: `make hook-test`
Expected: `all hook integration tests passed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStatusHook scripts/hook-integration-test.sh Makefile .github/workflows/ci.yml
git commit -m "feat: implement hook CLI with silent-exit contract and shell test"
```

---

### Task 8: Hook install/uninstall for ~/.claude/settings.json

**Files:**
- Create: `Sources/StatusBarCore/Hooks/HookSettingsMerger.swift`, `Sources/StatusBarCore/Hooks/HookInstaller.swift`
- Test: `Tests/StatusBarCoreTests/HookInstallTests.swift`

**Interfaces:**
- Consumes: `AtomicFile` (Task 2), `ISO8601` (Task 2).
- Produces:
  - `HookSettingsMerger` (pure, operates on `[String: Any]`):
    - `static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification"]`
    - `static func install(into settings: [String: Any], binaryPath: String) -> [String: Any]`
    - `static func remove(from settings: [String: Any]) -> [String: Any]`
    - `static func isInstalled(_ settings: [String: Any], binaryPath: String) -> Bool`
  - `HookInstaller`:
    - `init(settingsFile: URL, now: @escaping () -> Date = Date.init)`
    - `func status(binaryPath: String) throws -> Bool`
    - `func install(binaryPath: String) throws` / `func uninstall() throws` — backup → merge → JSON-validate → atomic write; throws `HookInstallError.invalidSettingsJSON` rather than writing a broken file.
  - Identity marker for "ours": the hook `command` string **contains `"claude-status-hook"`** — used by both `remove` and `isInstalled` so uninstall removes stale entries pointing at old binary paths too.
  - Claude Code settings shape produced: `{"hooks": {"<Event>": [{"matcher": "*", "hooks": [{"type": "command", "command": "<binaryPath> <Event>"}]}]}}` — the `matcher` key is included **only** for `PreToolUse`/`PostToolUse`.
  - Task 13's Settings pane calls `status/install/uninstall` with `defaultHookBinary()`.

- [ ] **Step 1: Write the failing tests**

`Tests/StatusBarCoreTests/HookInstallTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

private let bin = "/Applications/ClaudeStatusBar.app/Contents/MacOS/claude-status-hook"

@Suite struct HookSettingsMergerTests {
    @Test func installIntoEmptySettings() throws {
        let merged = HookSettingsMerger.install(into: [:], binaryPath: bin)
        let hooks = try #require(merged["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookSettingsMerger.events))

        let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 1)
        #expect(pre[0]["matcher"] as? String == "*")
        let entry = try #require((pre[0]["hooks"] as? [[String: Any]])?.first)
        #expect(entry["type"] as? String == "command")
        #expect(entry["command"] as? String == "\(bin) PreToolUse")

        // Non-tool events carry no matcher key
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop[0]["matcher"] == nil)
    }

    @Test func installPreservesForeignHooksAndIsIdempotent() throws {
        let foreign: [String: Any] = [
            "model": "opus",
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/guard.sh"]]]
                ]
            ],
        ]
        let once = HookSettingsMerger.install(into: foreign, binaryPath: bin)
        let twice = HookSettingsMerger.install(into: once, binaryPath: bin)

        #expect(twice["model"] as? String == "opus")
        let pre = try #require((twice["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 2)  // foreign + exactly one of ours
        let commands = pre.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands.filter { $0.contains("claude-status-hook") }.count == 1)
        #expect(commands.contains("/usr/local/bin/guard.sh"))
    }

    @Test func removeDropsOnlyOursAndCleansEmpties() throws {
        let foreign: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/guard.sh"]]]
                ]
            ]
        ]
        let installed = HookSettingsMerger.install(into: foreign, binaryPath: bin)
        let removed = HookSettingsMerger.remove(from: installed)

        let hooks = try #require(removed["hooks"] as? [String: Any])
        #expect(hooks["Stop"] == nil)          // ours-only event fully dropped
        let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 1)                // foreign entry survives

        // Removing from a settings dict where we're the ONLY content drops "hooks" entirely
        let onlyOurs = HookSettingsMerger.install(into: [:], binaryPath: bin)
        #expect(HookSettingsMerger.remove(from: onlyOurs)["hooks"] == nil)
    }

    @Test func removeMatchesStaleBinaryPaths() {
        let old = HookSettingsMerger.install(into: [:], binaryPath: "/old/path/claude-status-hook")
        #expect(HookSettingsMerger.remove(from: old)["hooks"] == nil)
    }

    @Test func isInstalledChecksAllEvents() {
        #expect(!HookSettingsMerger.isInstalled([:], binaryPath: bin))
        let full = HookSettingsMerger.install(into: [:], binaryPath: bin)
        #expect(HookSettingsMerger.isInstalled(full, binaryPath: bin))
        let partial = HookSettingsMerger.remove(from: full)
        #expect(!HookSettingsMerger.isInstalled(partial, binaryPath: bin))
    }
}

@Suite struct HookInstallerTests {
    private func tempSettingsFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @Test func installCreatesBackupAndValidJSON() throws {
        let file = tempSettingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try AtomicFile.write(Data(#"{"model":"opus"}"#.utf8), to: file)

        let fixed = Date(timeIntervalSince1970: 1_750_000_000)
        let installer = HookInstaller(settingsFile: file, now: { fixed })
        try installer.install(binaryPath: bin)

        #expect(try installer.status(binaryPath: bin))
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(written?["model"] as? String == "opus")

        let backup = file.deletingLastPathComponent()
            .appendingPathComponent("settings.json.claude-status-bar-backup-\(ISO8601.string(from: fixed))")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try Data(contentsOf: backup) == Data(#"{"model":"opus"}"#.utf8))
    }

    @Test func installOnMissingFileStartsFresh() throws {
        let file = tempSettingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let installer = HookInstaller(settingsFile: file)
        try installer.install(binaryPath: bin)
        #expect(try installer.status(binaryPath: bin))
    }

    @Test func uninstallRestoresForeignOnlySettings() throws {
        let file = tempSettingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try AtomicFile.write(Data(#"{"model":"opus"}"#.utf8), to: file)
        let installer = HookInstaller(settingsFile: file)
        try installer.install(binaryPath: bin)
        try installer.uninstall()

        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(after?["model"] as? String == "opus")
        #expect(after?["hooks"] == nil)
        #expect(try !installer.status(binaryPath: bin))
    }

    @Test func corruptSettingsFileThrowsWithoutWriting() throws {
        let file = tempSettingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try AtomicFile.write(Data("{broken".utf8), to: file)
        let installer = HookInstaller(settingsFile: file)
        #expect(throws: HookInstallError.self) { try installer.install(binaryPath: bin) }
        #expect(try Data(contentsOf: file) == Data("{broken".utf8))  // untouched
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HookSettingsMergerTests`
Expected: COMPILE ERROR — `cannot find 'HookSettingsMerger' in scope`.

- [ ] **Step 3: Implement**

`Sources/StatusBarCore/Hooks/HookSettingsMerger.swift`:

```swift
import Foundation

/// Pure merge logic for Claude Code's ~/.claude/settings.json hook entries.
/// Works on [String: Any] because settings.json is user-owned free-form JSON:
/// everything we don't understand must round-trip untouched.
public enum HookSettingsMerger {
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "Stop", "Notification",
    ]
    private static let marker = "claude-status-hook"
    private static let matcherEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    public static func install(into settings: [String: Any], binaryPath: String) -> [String: Any] {
        var result = remove(from: settings)  // idempotency: drop any prior entry of ours
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": "\(binaryPath) \(event)"]]
            ]
            if matcherEvents.contains(event) { entry["matcher"] = "*" }
            var list = hooks[event] as? [[String: Any]] ?? []
            list.append(entry)
            hooks[event] = list
        }
        result["hooks"] = hooks
        return result
    }

    public static func remove(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = result["hooks"] as? [String: Any] else { return result }
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else { continue }
            let kept = list.filter { !isOurs($0) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return result
    }

    public static func isInstalled(_ settings: [String: Any], binaryPath: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            guard let list = hooks[event] as? [[String: Any]] else { return false }
            return list.contains { entry in
                commands(of: entry).contains { $0.hasPrefix("\(binaryPath) ") }
            }
        }
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        commands(of: entry).contains { $0.contains(marker) }
    }

    private static func commands(of entry: [String: Any]) -> [String] {
        ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
    }
}
```

`Sources/StatusBarCore/Hooks/HookInstaller.swift`:

```swift
import Foundation

public enum HookInstallError: Error, Equatable {
    case invalidSettingsJSON
}

/// File-level orchestration: backup -> merge -> validate -> atomic write.
public struct HookInstaller {
    let settingsFile: URL
    let now: () -> Date

    public init(settingsFile: URL, now: @escaping () -> Date = Date.init) {
        self.settingsFile = settingsFile
        self.now = now
    }

    public func status(binaryPath: String) throws -> Bool {
        HookSettingsMerger.isInstalled(try readSettings(), binaryPath: binaryPath)
    }

    public func install(binaryPath: String) throws {
        try mutate { HookSettingsMerger.install(into: $0, binaryPath: binaryPath) }
    }

    public func uninstall() throws {
        try mutate { HookSettingsMerger.remove(from: $0) }
    }

    private func mutate(_ transform: ([String: Any]) -> [String: Any]) throws {
        if let existing = try? Data(contentsOf: settingsFile) {
            let backup = settingsFile.deletingLastPathComponent().appendingPathComponent(
                "\(settingsFile.lastPathComponent).claude-status-bar-backup-\(ISO8601.string(from: now()))")
            try AtomicFile.write(existing, to: backup)
        }
        let merged = transform(try readSettings())
        guard JSONSerialization.isValidJSONObject(merged) else {
            throw HookInstallError.invalidSettingsJSON
        }
        let data = try JSONSerialization.data(
            withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try AtomicFile.write(data, to: settingsFile)
    }

    private func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsFile), !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallError.invalidSettingsJSON
        }
        return obj
    }
}
```

Note: `corruptSettingsFileThrowsWithoutWriting` passes because `readSettings()` throws before any write — but `mutate` backs up first, which is fine (backup of a corrupt file is harmless); the settings file itself is untouched. The test asserts exactly that.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — `Test run with 47 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Hooks Tests
git commit -m "feat: merge and remove Claude Code hook entries safely"
```

---

### Task 9: UsageClient + UsageStore

**Files:**
- Create: `Sources/StatusBarCore/Usage/UsageClient.swift`, `Sources/StatusBarCore/Usage/UsageStore.swift`
- Test: `Tests/StatusBarCoreTests/UsageClientTests.swift`, `Tests/StatusBarCoreTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `UsageSnapshot`, `UsageWindow` (Task 3); `Account` (Task 4); `AtomicFile`, `AppPaths` (Task 2).
- Produces:
  - `protocol UsageFetching: Sendable { func fetch(token: String) async throws -> UsageSnapshot }`
  - `UsageClient: UsageFetching` — real URLSession client. `init(session: URLSession = .shared)`. GET `https://api.anthropic.com/api/oauth/usage`, headers exactly `Authorization: Bearer <token>` and `User-Agent: claude-code/2.1.197`. Throws `UsageError`.
  - `enum UsageError: Error, Equatable { case unauthorized, rateLimited, http(Int), network, malformed }` — 401→`.unauthorized`, 429→`.rateLimited`, other non-2xx→`.http(code)`, URLSession error→`.network`, unparseable body→`.malformed`.
  - `AccountUsageState: Equatable, Sendable` — `snapshot: UsageSnapshot?`, `freshness: Freshness` (`enum Freshness { case fresh, stale, none }`), `needsRelogin: Bool`, `failureCount: Int`.
  - `UsageStore` (`@MainActor final class`):
    - `init(fetcher: UsageFetching, cacheFile: URL)`
    - `private(set) var states: [String: AccountUsageState]` keyed by `Account.id`
    - `func refresh(accounts: [(account: Account, token: String?)]) async` — fetches all accounts concurrently (task group), per-account isolation: one failure never blocks others. Success → `fresh`, `failureCount = 0`, `needsRelogin = false`. `.unauthorized` → keep old snapshot, `stale`, `needsRelogin = true`. Other errors → keep old snapshot, `stale`, `failureCount += 1`. Nil token → `needsRelogin = true`. Saves cache after each refresh.
    - `static func shouldSkip(cycle: Int, failureCount: Int) -> Bool` — pure backoff: skip when `cycle % min(2^failureCount, 8) != 0` (failureCount 0 → never skip; 1 → every 2nd cycle; 2 → every 4th; ≥3 → every 8th).
    - `func loadCache()` / cache saved as `[String: UsageSnapshot]` via Codable; cached entries load as `.stale`.
- Tests use a mock `UsageFetching` for the store, and `URLProtocol` for the client (suite `.serialized` because `URLProtocol` registration is global).

- [ ] **Step 1: Write the failing tests**

`Tests/StatusBarCoreTests/UsageClientTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

/// Global stub for URLProtocol — one handler at a time, hence .serialized.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct UsageClientTests {
    private func makeClient() -> UsageClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return UsageClient(session: URLSession(configuration: config))
    }

    @Test func fetchParsesGoodResponse() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.197")
            return (200, Data(#"{"five_hour":{"utilization":42},"seven_day":{"utilization":7}}"#.utf8))
        }
        let snapshot = try await makeClient().fetch(token: "fake-token")
        #expect(snapshot.fiveHour?.utilization == 42)
        #expect(snapshot.sevenDay?.utilization == 7)
    }

    @Test func statusCodesMapToErrors() async {
        for (status, expected) in [(401, UsageError.unauthorized),
                                   (429, UsageError.rateLimited),
                                   (500, UsageError.http(500))] {
            StubURLProtocol.handler = { _ in (status, Data()) }
            await #expect(throws: expected) { try await makeClient().fetch(token: "fake") }
        }
    }

    @Test func garbageBodyIsMalformed() async {
        StubURLProtocol.handler = { _ in (200, Data("<html>".utf8)) }
        await #expect(throws: UsageError.malformed) { try await makeClient().fetch(token: "fake") }
    }

    @Test func transportFailureIsNetwork() async {
        StubURLProtocol.handler = nil  // startLoading fails -> URLError
        await #expect(throws: UsageError.network) { try await makeClient().fetch(token: "fake") }
    }
}
```

`Tests/StatusBarCoreTests/UsageStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

/// Scripted fetcher: token -> result, so per-account behavior is controllable.
struct MockFetcher: UsageFetching {
    let results: [String: Result<UsageSnapshot, UsageError>]
    func fetch(token: String) async throws -> UsageSnapshot {
        switch results[token] {
        case .success(let snap): return snap
        case .failure(let err): throw err
        case nil: throw UsageError.network
        }
    }
}

private func snap(_ pct: Double) -> UsageSnapshot {
    UsageSnapshot(fiveHour: UsageWindow(utilization: pct),
                  sevenDay: UsageWindow(utilization: pct),
                  fetchedAt: Date(timeIntervalSince1970: 0))
}

private func account(_ id: String) -> Account {
    Account(id: id, alias: id, email: "\(id)@example.com", slot: nil,
            isActive: false, oauthURL: nil)
}

@MainActor
private func makeStore(_ results: [String: Result<UsageSnapshot, UsageError>]) -> (UsageStore, URL) {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("usage-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("usage-cache.json")
    return (UsageStore(fetcher: MockFetcher(results: results), cacheFile: cache), cache)
}

@MainActor @Suite struct UsageStoreTests {
    @Test func successMakesFreshFailureIsolated() async {
        let (store, cache) = makeStore(["tok-a": .success(snap(42)), "tok-b": .failure(.network)])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), "tok-a"), (account("b"), "tok-b")])

        #expect(store.states["a"]?.freshness == .fresh)
        #expect(store.states["a"]?.snapshot?.fiveHour?.utilization == 42)
        #expect(store.states["b"]?.freshness == .stale)
        #expect(store.states["b"]?.snapshot == nil)
        #expect(store.states["b"]?.failureCount == 1)
    }

    @Test func failureKeepsPreviousSnapshot() async {
        let (store, cache) = makeStore(["tok": .success(snap(10))])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), "tok")])
        await store.refresh(accounts: [(account("a"), "bad-tok")])  // unknown token -> .network

        #expect(store.states["a"]?.snapshot?.fiveHour?.utilization == 10)  // old data kept
        #expect(store.states["a"]?.freshness == .stale)
        #expect(store.states["a"]?.failureCount == 1)
    }

    @Test func unauthorizedSetsNeedsRelogin() async {
        let (store, cache) = makeStore(["tok": .failure(.unauthorized)])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), "tok")])
        #expect(store.states["a"]?.needsRelogin == true)
        #expect(store.states["a"]?.freshness == .stale)
    }

    @Test func missingTokenNeedsRelogin() async {
        let (store, cache) = makeStore([:])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), nil)])
        #expect(store.states["a"]?.needsRelogin == true)
        #expect(store.states["a"]?.snapshot == nil)
    }

    @Test func cacheRoundTripLoadsAsStale() async {
        let (store, cache) = makeStore(["tok": .success(snap(55))])
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        await store.refresh(accounts: [(account("a"), "tok")])

        let warm = UsageStore(fetcher: MockFetcher(results: [:]), cacheFile: cache)
        warm.loadCache()
        #expect(warm.states["a"]?.snapshot?.fiveHour?.utilization == 55)
        #expect(warm.states["a"]?.freshness == .stale)
    }

    @Test func backoffSchedule() {
        // failureCount 0: never skip
        #expect(!UsageStore.shouldSkip(cycle: 0, failureCount: 0))
        #expect(!UsageStore.shouldSkip(cycle: 3, failureCount: 0))
        // failureCount 1: every 2nd cycle runs
        #expect(!UsageStore.shouldSkip(cycle: 2, failureCount: 1))
        #expect(UsageStore.shouldSkip(cycle: 3, failureCount: 1))
        // failureCount 2: every 4th
        #expect(!UsageStore.shouldSkip(cycle: 4, failureCount: 2))
        #expect(UsageStore.shouldSkip(cycle: 6, failureCount: 2))
        // failureCount >= 3 caps at every 8th
        #expect(!UsageStore.shouldSkip(cycle: 8, failureCount: 5))
        #expect(UsageStore.shouldSkip(cycle: 12, failureCount: 5))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UsageClientTests`
Expected: COMPILE ERROR — `cannot find 'UsageClient' in scope`.

- [ ] **Step 3: Implement**

`Sources/StatusBarCore/Usage/UsageClient.swift`:

```swift
import Foundation

public enum UsageError: Error, Equatable {
    case unauthorized
    case rateLimited
    case http(Int)
    case network
    case malformed
}

public protocol UsageFetching: Sendable {
    func fetch(token: String) async throws -> UsageSnapshot
}

/// Real client for GET https://api.anthropic.com/api/oauth/usage.
/// The token lives only in the request header — never stored or logged.
public struct UsageClient: UsageFetching {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("claude-code/2.1.197", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.network }
        switch http.statusCode {
        case 200...299: break
        case 401: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited
        default: throw UsageError.http(http.statusCode)
        }
        guard let snapshot = UsageSnapshot.parse(data, fetchedAt: Date()) else {
            throw UsageError.malformed
        }
        return snapshot
    }
}
```

`Sources/StatusBarCore/Usage/UsageStore.swift`:

```swift
import Foundation

public enum Freshness: Equatable, Sendable {
    case fresh, stale, none
}

public struct AccountUsageState: Equatable, Sendable {
    public var snapshot: UsageSnapshot?
    public var freshness: Freshness
    public var needsRelogin: Bool
    public var failureCount: Int

    public init(snapshot: UsageSnapshot? = nil, freshness: Freshness = .none,
                needsRelogin: Bool = false, failureCount: Int = 0) {
        self.snapshot = snapshot
        self.freshness = freshness
        self.needsRelogin = needsRelogin
        self.failureCount = failureCount
    }
}

@MainActor
public final class UsageStore {
    let fetcher: UsageFetching
    let cacheFile: URL
    public private(set) var states: [String: AccountUsageState] = [:]

    public init(fetcher: UsageFetching, cacheFile: URL) {
        self.fetcher = fetcher
        self.cacheFile = cacheFile
    }

    /// Exponential per-account backoff after failures, capped at every 8th cycle.
    public static func shouldSkip(cycle: Int, failureCount: Int) -> Bool {
        guard failureCount > 0 else { return false }
        let interval = min(1 << failureCount, 8)
        return cycle % interval != 0
    }

    public func refresh(accounts: [(account: Account, token: String?)]) async {
        let fetcher = self.fetcher
        let results = await withTaskGroup(
            of: (String, Result<UsageSnapshot, UsageError>?).self
        ) { group in
            for (account, token) in accounts {
                group.addTask {
                    guard let token else { return (account.id, nil) }
                    do {
                        return (account.id, .success(try await fetcher.fetch(token: token)))
                    } catch let error as UsageError {
                        return (account.id, .failure(error))
                    } catch {
                        return (account.id, .failure(.network))
                    }
                }
            }
            var collected: [(String, Result<UsageSnapshot, UsageError>?)] = []
            for await item in group { collected.append(item) }
            return collected
        }

        for (id, result) in results {
            var state = states[id] ?? AccountUsageState()
            switch result {
            case .success(let snapshot):
                state = AccountUsageState(snapshot: snapshot, freshness: .fresh)
            case .failure(.unauthorized):
                state.freshness = .stale
                state.needsRelogin = true
                state.failureCount += 1
            case .failure:
                state.freshness = .stale
                state.failureCount += 1
            case nil:  // no token available
                state.needsRelogin = true
            }
            states[id] = state
        }
        saveCache()
    }

    public func loadCache() {
        guard let data = try? Data(contentsOf: cacheFile),
              let cached = try? decoder().decode([String: UsageSnapshot].self, from: data)
        else { return }
        for (id, snapshot) in cached where states[id] == nil {
            states[id] = AccountUsageState(snapshot: snapshot, freshness: .stale)
        }
    }

    private func saveCache() {
        let snapshots = states.compactMapValues(\.snapshot)
        guard let data = try? encoder().encode(snapshots) else { return }
        try? AtomicFile.write(data, to: cacheFile)
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
```

**Prerequisite check for this task:** `UsageSnapshot`/`UsageWindow` (Task 3) must be `Codable` for the cache. Task 3 defines them as plain structs — if `Codable` conformance is missing, add `Codable` to both type declarations in `Sources/StatusBarCore/Usage/UsageModels.swift` as part of this task (their fields are all `Double?`/`Date` — synthesized conformance suffices).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — `Test run with 57 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Usage Tests
git commit -m "feat: fetch usage per account with isolation, backoff, disk cache"
```

---

### Task 10: Menu bar text formatting + thinking verbs

**Files:**
- Create: `Sources/StatusBarCore/Display/MenuBarText.swift`, `Sources/StatusBarCore/Display/ThinkingVerbs.swift`
- Test: `Tests/StatusBarCoreTests/MenuBarTextTests.swift`

**Interfaces:**
- Consumes: `SessionRecord`, `SessionState` (Task 5); `UsageSnapshot`, `UsageLevel`, `level(for:yellowAt:redAt:)` (Task 3); `AccountUsageState` (Task 9).
- Produces:
  - `DisplayStyle: String, CaseIterable` — `.iconOnly`, `.percent`, `.full` (raw values `"iconOnly"`, `"percent"`, `"full"` — Task 13's SettingsStore persists the raw value).
  - `MenuBarLabelModel: Equatable` — `state: SessionState`, `activityText: String?`, `usageText: String?`, `fiveHourLevel: UsageLevel?`, `sevenDayLevel: UsageLevel?`.
  - `MenuBarText.model(display: SessionRecord?, usage: AccountUsageState?, style: DisplayStyle, showUsage: Bool, yellowAt: Double, redAt: Double, verb: String, now: Date) -> MenuBarLabelModel`:
    - `activityText`: nil for `.iconOnly` or when idle/no session. `.tool` → `"<label> · <elapsed>"`; `.thinking` → `"<verb>… · <elapsed>"`; `.waiting` → `"Waiting for you"`. Elapsed from `busySince`.
    - `usageText`: nil unless `showUsage` and style is `.percent`/`.full` and a snapshot exists. `.percent` → `"71%"` (5h only); `.full` → `"5h 71% · 7d 29%"`. Percentages rounded to nearest int.
  - `MenuBarText.elapsed(_ interval: TimeInterval) -> String` — `"45s"` under 1 min; `"3m 12s"` under 1 h; `"1h 04m"` from 1 h (minutes zero-padded).
  - `ThinkingVerbs.all: [String]` (28 entries) and `struct VerbCycler` — `init(rng: @escaping () -> Double = { Double.random(in: 0..<1) })`, `mutating func next() -> String` — uniform pick, never the same verb twice in a row.

- [ ] **Step 1: Write the failing tests**

`Tests/StatusBarCoreTests/MenuBarTextTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

private let now = Date(timeIntervalSince1970: 100_000)

private func session(_ state: SessionState, label: String? = nil,
                     busyFor: TimeInterval? = nil) -> SessionRecord {
    SessionRecord(sessionId: "s", state: state, label: label, cwd: "/tmp/proj",
                  startedAt: now.addingTimeInterval(-600),
                  busySince: busyFor.map { now.addingTimeInterval(-$0) }, updatedAt: now)
}

private func usage(five: Double, seven: Double) -> AccountUsageState {
    AccountUsageState(
        snapshot: UsageSnapshot(fiveHour: UsageWindow(utilization: five),
                                sevenDay: UsageWindow(utilization: seven),
                                fetchedAt: now),
        freshness: .fresh)
}

@Suite struct ElapsedTests {
    @Test func formats() {
        #expect(MenuBarText.elapsed(45) == "45s")
        #expect(MenuBarText.elapsed(192) == "3m 12s")
        #expect(MenuBarText.elapsed(3_840) == "1h 04m")
        #expect(MenuBarText.elapsed(0) == "0s")
    }
}

@Suite struct MenuBarTextTests {
    private func model(display: SessionRecord?, usage: AccountUsageState?,
                       style: DisplayStyle, showUsage: Bool = true) -> MenuBarLabelModel {
        MenuBarText.model(display: display, usage: usage, style: style,
                          showUsage: showUsage, yellowAt: 50, redAt: 80,
                          verb: "Pondering", now: now)
    }

    @Test func toolStateShowsLabelAndElapsed() {
        let m = model(display: session(.tool, label: "Running", busyFor: 192),
                      usage: nil, style: .full)
        #expect(m.state == .tool)
        #expect(m.activityText == "Running · 3m 12s")
    }

    @Test func thinkingUsesVerb() {
        let m = model(display: session(.thinking, busyFor: 45), usage: nil, style: .full)
        #expect(m.activityText == "Pondering… · 45s")
    }

    @Test func waitingHasFixedText() {
        let m = model(display: session(.waiting, busyFor: 45), usage: nil, style: .full)
        #expect(m.activityText == "Waiting for you")
    }

    @Test func idleAndIconOnlyShowNoActivity() {
        #expect(model(display: session(.idle), usage: nil, style: .full).activityText == nil)
        #expect(model(display: nil, usage: nil, style: .full).activityText == nil)
        let m = model(display: session(.tool, label: "Running", busyFor: 10),
                      usage: usage(five: 71, seven: 29), style: .iconOnly)
        #expect(m.activityText == nil)
        #expect(m.usageText == nil)
    }

    @Test func usageTextPerStyle() {
        let u = usage(five: 70.6, seven: 29.2)
        #expect(model(display: nil, usage: u, style: .full).usageText == "5h 71% · 7d 29%")
        #expect(model(display: nil, usage: u, style: .percent).usageText == "71%")
        #expect(model(display: nil, usage: u, style: .full, showUsage: false).usageText == nil)
        #expect(model(display: nil, usage: nil, style: .full).usageText == nil)
    }

    @Test func levelsComputedFromThresholds() {
        let m = model(display: nil, usage: usage(five: 85, seven: 55), style: .full)
        #expect(m.fiveHourLevel == .red)
        #expect(m.sevenDayLevel == .yellow)
        #expect(model(display: nil, usage: nil, style: .full).fiveHourLevel == nil)
    }
}

@Suite struct ThinkingVerbsTests {
    @Test func has28UniqueVerbs() {
        #expect(ThinkingVerbs.all.count == 28)
        #expect(Set(ThinkingVerbs.all).count == 28)
    }

    @Test func neverRepeatsImmediately() {
        // rng always returns 0 -> would always pick index 0 without the no-repeat rule
        var cycler = VerbCycler(rng: { 0 })
        let first = cycler.next()
        let second = cycler.next()
        #expect(first != second)

        var random = VerbCycler()
        var previous = random.next()
        for _ in 0..<200 {
            let verb = random.next()
            #expect(verb != previous)
            #expect(ThinkingVerbs.all.contains(verb))
            previous = verb
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MenuBarTextTests`
Expected: COMPILE ERROR — `cannot find 'MenuBarText' in scope`.

- [ ] **Step 3: Implement**

`Sources/StatusBarCore/Display/MenuBarText.swift`:

```swift
import Foundation

public enum DisplayStyle: String, CaseIterable, Sendable {
    case iconOnly, percent, full
}

public struct MenuBarLabelModel: Equatable, Sendable {
    public let state: SessionState
    public let activityText: String?
    public let usageText: String?
    public let fiveHourLevel: UsageLevel?
    public let sevenDayLevel: UsageLevel?
}

public enum MenuBarText {
    public static func model(display: SessionRecord?, usage: AccountUsageState?,
                             style: DisplayStyle, showUsage: Bool,
                             yellowAt: Double, redAt: Double,
                             verb: String, now: Date) -> MenuBarLabelModel {
        let state = display?.state ?? .idle

        var activity: String?
        if style != .iconOnly, let display {
            let time = display.busySince.map { elapsed(now.timeIntervalSince($0)) }
            switch display.state {
            case .tool:
                let label = display.label ?? "Working"
                activity = time.map { "\(label) · \($0)" } ?? label
            case .thinking:
                activity = time.map { "\(verb)… · \($0)" } ?? "\(verb)…"
            case .waiting:
                activity = "Waiting for you"
            case .idle:
                activity = nil
            }
        }

        var usageText: String?
        var fiveLevel: UsageLevel?
        var sevenLevel: UsageLevel?
        if showUsage, style != .iconOnly, let snapshot = usage?.snapshot {
            let five = snapshot.fiveHour.map { Int($0.utilization.rounded()) }
            let seven = snapshot.sevenDay.map { Int($0.utilization.rounded()) }
            fiveLevel = snapshot.fiveHour.map {
                level(for: $0.utilization, yellowAt: yellowAt, redAt: redAt)
            }
            sevenLevel = snapshot.sevenDay.map {
                level(for: $0.utilization, yellowAt: yellowAt, redAt: redAt)
            }
            switch style {
            case .percent:
                usageText = five.map { "\($0)%" }
            case .full:
                let parts = [five.map { "5h \($0)%" }, seven.map { "7d \($0)%" }]
                    .compactMap(\.self)
                usageText = parts.isEmpty ? nil : parts.joined(separator: " · ")
            case .iconOnly:
                usageText = nil
            }
        }

        return MenuBarLabelModel(state: state, activityText: activity,
                                 usageText: usageText,
                                 fiveHourLevel: fiveLevel, sevenDayLevel: sevenLevel)
    }

    public static func elapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        let minutes = (total % 3_600) / 60
        return "\(total / 3_600)h \(String(format: "%02d", minutes))m"
    }
}
```

`Sources/StatusBarCore/Display/ThinkingVerbs.swift`:

```swift
import Foundation

public enum ThinkingVerbs {
    public static let all = [
        "Brewing", "Pondering", "Scheming", "Musing", "Percolating", "Ruminating",
        "Noodling", "Cogitating", "Marinating", "Simmering", "Untangling", "Weighing",
        "Sketching", "Plotting", "Dreaming", "Tinkering", "Digesting", "Mulling",
        "Hatching", "Stewing", "Whirring", "Conjuring", "Assembling", "Distilling",
        "Deliberating", "Incubating", "Composing", "Calibrating",
    ]
}

/// Uniform random verb picker that never repeats the previous verb.
public struct VerbCycler {
    let rng: () -> Double
    var previousIndex: Int?

    public init(rng: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.rng = rng
    }

    public mutating func next() -> String {
        let verbs = ThinkingVerbs.all
        // Draw from the pool minus the previous pick, then map back to full indices.
        let poolSize = previousIndex == nil ? verbs.count : verbs.count - 1
        var index = min(Int(rng() * Double(poolSize)), poolSize - 1)
        if let previous = previousIndex, index >= previous { index += 1 }
        previousIndex = index
        return verbs[index]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS — `Test run with 66 tests passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Display Tests
git commit -m "feat: format menu bar label with thinking verbs and elapsed time"
```

---

### Task 11: App shell — AppState, directory watcher, menu bar label

**Files:**
- Create: `Sources/StatusBarCore/Display/StatusIcon.swift` (pure mapping — testable)
- Create: `Sources/ClaudeStatusBar/DirectoryWatcher.swift`, `Sources/ClaudeStatusBar/AppState.swift`, `Sources/ClaudeStatusBar/MenuBarLabelView.swift`
- Modify: `Sources/ClaudeStatusBar/ClaudeStatusBarApp.swift` (replace the Task 1 stub)
- Test: `Tests/StatusBarCoreTests/StatusIconTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–10.
- Produces:
  - `ClawdIcon: String, Equatable` enum — cases `idle, thinking, notification, typing, building, debugger, carrying`; `rawValue` is the artwork file basename (Task 14 downloads `<rawValue>.webp` → `.png`); `var sfFallback: String` (SF Symbol name used when artwork is missing).
  - `StatusIcon.icon(for record: SessionRecord?) -> ClawdIcon` — nil or `.idle` → `.idle`; `.thinking` → `.thinking`; `.waiting` → `.notification`; `.tool` by label: "Editing"→`.typing`, "Running"→`.building`, "Searching"→`.debugger`, "Reading"→`.carrying`, anything else→`.typing`.
  - `AppState` (`@Observable @MainActor final class`) — the app's single source of truth: `sessions: [SessionRecord]`, `display: SessionRecord?`, `accounts: [Account]`, `usageStore: UsageStore`, `currentVerb: String`, `func start()`, `func reaggregate()`, `func refreshUsageNow()`. Task 12's popover and Task 13's settings both hang off this object. Poll interval / thresholds / style are **constants in this task** (5 min, 50/80, `.full`); Task 13 replaces them with `SettingsStore` reads.
  - `MenuBarLabelView: View` — renders `MenuBarLabelModel` + `ClawdIcon` inside the `MenuBarExtra` label.

UI behavior is not unit-testable headlessly; this task's test cycle = `StatusIconTests` (pure logic) + `swift build` + a manual smoke step. SMAppService/launch-at-login is Task 13.

- [ ] **Step 1: Write the failing tests**

`Tests/StatusBarCoreTests/StatusIconTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

private func record(_ state: SessionState, label: String? = nil) -> SessionRecord {
    let now = Date(timeIntervalSince1970: 0)
    return SessionRecord(sessionId: "s", state: state, label: label, cwd: "/tmp",
                         startedAt: now, busySince: nil, updatedAt: now)
}

@Suite struct StatusIconTests {
    @Test func statesMapToIcons() {
        #expect(StatusIcon.icon(for: nil) == .idle)
        #expect(StatusIcon.icon(for: record(.idle)) == .idle)
        #expect(StatusIcon.icon(for: record(.thinking)) == .thinking)
        #expect(StatusIcon.icon(for: record(.waiting)) == .notification)
    }

    @Test func toolLabelsMapToIcons() {
        #expect(StatusIcon.icon(for: record(.tool, label: "Editing")) == .typing)
        #expect(StatusIcon.icon(for: record(.tool, label: "Running")) == .building)
        #expect(StatusIcon.icon(for: record(.tool, label: "Searching")) == .debugger)
        #expect(StatusIcon.icon(for: record(.tool, label: "Reading")) == .carrying)
        #expect(StatusIcon.icon(for: record(.tool, label: "Browsing")) == .typing)
        #expect(StatusIcon.icon(for: record(.tool, label: nil)) == .typing)
    }

    @Test func rawValuesMatchArtworkBasenames() {
        #expect(Set(ClawdIcon.allCases.map(\.rawValue)) ==
                ["idle", "thinking", "notification", "typing", "building",
                 "debugger", "carrying"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter StatusIconTests`
Expected: COMPILE ERROR — `cannot find 'StatusIcon' in scope`.

- [ ] **Step 3: Implement StatusIcon in StatusBarCore**

`Sources/StatusBarCore/Display/StatusIcon.swift`:

```swift
import Foundation

/// Clawd artwork variants. rawValue == artwork file basename in Resources/clawd.
public enum ClawdIcon: String, CaseIterable, Equatable, Sendable {
    case idle, thinking, notification, typing, building, debugger, carrying

    /// SF Symbol used when the artwork file is missing from the bundle.
    public var sfFallback: String {
        switch self {
        case .idle: return "moon.zzz"
        case .thinking: return "brain"
        case .notification: return "bell.badge"
        case .typing: return "keyboard"
        case .building: return "hammer"
        case .debugger: return "magnifyingglass"
        case .carrying: return "book"
        }
    }
}

public enum StatusIcon {
    public static func icon(for record: SessionRecord?) -> ClawdIcon {
        guard let record else { return .idle }
        switch record.state {
        case .idle: return .idle
        case .thinking: return .thinking
        case .waiting: return .notification
        case .tool:
            switch record.label {
            case "Editing": return .typing
            case "Running": return .building
            case "Searching": return .debugger
            case "Reading": return .carrying
            default: return .typing
            }
        }
    }
}
```

Run: `swift test` — Expected: PASS (69 tests).

- [ ] **Step 4: Implement DirectoryWatcher**

`Sources/ClaudeStatusBar/DirectoryWatcher.swift`:

```swift
import Foundation

/// Watches one directory for writes via DispatchSource (kqueue under the hood).
/// Calls onChange on the main queue. The directory must exist when init runs.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            source = nil
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }
}
```

- [ ] **Step 5: Implement AppState**

`Sources/ClaudeStatusBar/AppState.swift`:

```swift
import Foundation
import Observation
import StatusBarCore

/// Single source of truth for the UI. Task 13 replaces the constants below
/// with SettingsStore-backed values.
@Observable @MainActor
final class AppState {
    // Settings constants until Task 13 wires SettingsStore.
    let pollMinutes = 5
    let yellowAt: Double = 50
    let redAt: Double = 80
    let displayStyle: DisplayStyle = .full
    let showUsageOnBar = true

    private(set) var sessions: [SessionRecord] = []
    private(set) var display: SessionRecord?
    private(set) var accounts: [Account] = []
    private(set) var currentVerb: String
    let usageStore: UsageStore
    let paths: AppPaths

    private var verbCycler = VerbCycler()
    private var watcher: DirectoryWatcher?
    private var pollTask: Task<Void, Never>?
    private var reaggregateTask: Task<Void, Never>?
    private var pollCycle = 0

    private let cuxRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cux", isDirectory: true)
    private let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    init(paths: AppPaths = AppPaths()) {
        self.paths = paths
        self.usageStore = UsageStore(fetcher: UsageClient(), cacheFile: paths.usageCacheFile)
        self.currentVerb = ThinkingVerbs.all[0]
        self.currentVerb = verbCycler.next()
    }

    func start() {
        try? paths.ensureDirs()
        usageStore.loadCache()
        accounts = AccountDiscovery.discover(cuxRoot: cuxRoot, credentialsFile: credentialsFile)
        reaggregate()

        watcher = DirectoryWatcher(url: paths.sessionsDir) { [weak self] in
            self?.reaggregate()
        }
        // Safety net: stale sessions must disappear even with no file events.
        reaggregateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.reaggregate()
            }
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let minutes = self?.pollMinutes ?? 5
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }

    func reaggregate() {
        sessions = SessionAggregator.loadSessions(from: paths.sessionsDir, now: Date())
        let previous = display?.state
        display = SessionAggregator.displayState(sessions)
        if display?.state == .thinking, previous != .thinking {
            currentVerb = verbCycler.next()
        }
    }

    func refreshUsageNow() async {
        accounts = AccountDiscovery.discover(cuxRoot: cuxRoot, credentialsFile: credentialsFile)
        await usageStore.refresh(accounts: accounts.map { ($0, token(for: $0)) })
    }

    var labelModel: MenuBarLabelModel {
        let activeUsage = accounts.first(where: \.isActive).flatMap { usageStore.states[$0.id] }
            ?? accounts.first.flatMap { usageStore.states[$0.id] }
        return MenuBarText.model(display: display, usage: activeUsage,
                                 style: displayStyle, showUsage: showUsageOnBar,
                                 yellowAt: yellowAt, redAt: redAt,
                                 verb: currentVerb, now: Date())
    }

    private func pollOnce() async {
        accounts = AccountDiscovery.discover(cuxRoot: cuxRoot, credentialsFile: credentialsFile)
        let cycle = pollCycle
        pollCycle += 1
        let due = accounts.filter { account in
            let failures = usageStore.states[account.id]?.failureCount ?? 0
            return !UsageStore.shouldSkip(cycle: cycle, failureCount: failures)
        }
        guard !due.isEmpty else { return }
        await usageStore.refresh(accounts: due.map { ($0, token(for: $0)) })
    }

    /// Token is read at fetch time only, kept in a local, never stored or logged.
    private func token(for account: Account) -> String? {
        guard let url = account.oauthURL, let data = try? Data(contentsOf: url) else {
            return nil
        }
        return AccountDiscovery.accessToken(from: data)
    }
}
```

- [ ] **Step 6: Implement the menu bar label view and app entry**

`Sources/ClaudeStatusBar/MenuBarLabelView.swift`:

```swift
import SwiftUI
import StatusBarCore

struct MenuBarLabelView: View {
    let model: MenuBarLabelModel
    let icon: ClawdIcon

    var body: some View {
        // MenuBarExtra labels render Text + Image only; colors are flattened
        // to template by the system, so levels are shown via dots in the popover,
        // not here.
        HStack(spacing: 4) {
            iconImage
            if let text = barText {
                Text(text)
            }
        }
    }

    private var barText: String? {
        let parts = [model.activityText, model.usageText].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private var iconImage: Image {
        if let url = Bundle.module.url(forResource: "clawd/\(icon.rawValue)",
                                       withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            nsImage.size = NSSize(width: 18, height: 18)
            return Image(nsImage: nsImage).renderingMode(.original)
        }
        return Image(systemName: icon.sfFallback)
    }
}
```

Replace `Sources/ClaudeStatusBar/ClaudeStatusBarApp.swift`:

```swift
import SwiftUI
import StatusBarCore

@main
struct ClaudeStatusBarApp: App {
    @State private var appState = AppState()

    init() {
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            // Popover content arrives in Task 12; placeholder is functional.
            VStack(spacing: 8) {
                Text("Claude Status Bar").font(.headline)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .padding()
            .task {
                appState.start()
                await appState.refreshUsageNow()
            }
        } label: {
            // TimelineView ticks the elapsed counter while a session is busy.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                MenuBarLabelView(model: appState.labelModel,
                                 icon: StatusIcon.icon(for: appState.display))
            }
        }
        .menuBarExtraStyle(.window)
    }
}
```

Note: `.task` on the popover content only fires when the popover first opens; `start()` must run at launch. Move it: add an `@State private var started = false` guard is one option, but simplest correct form is starting from the label view's `.onAppear` (the label exists from launch). Use exactly this in the label closure:

```swift
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                MenuBarLabelView(model: appState.labelModel,
                                 icon: StatusIcon.icon(for: appState.display))
            }
            .onAppear {
                appState.start()
                Task { await appState.refreshUsageNow() }
            }
        }
```

and drop the `.task` from the popover content (keep the placeholder VStack).

- [ ] **Step 7: Build and smoke-test**

Run: `swift build && swift test`
Expected: builds clean, 69 tests pass.

Manual smoke (cannot be asserted in CI — run it, observe, then continue):

```bash
swift run ClaudeStatusBar
```

Expected: a Clawd (or SF-symbol fallback) icon appears in the menu bar; with cux configured, usage text like `5h 71% · 7d 29%` appears within a few seconds; clicking shows the placeholder popover with a working Quit button. Ctrl-C in the terminal also quits.

- [ ] **Step 8: Commit**

```bash
git add Sources/StatusBarCore/Display/StatusIcon.swift Sources/ClaudeStatusBar Tests
git commit -m "feat: add app shell with live menu bar label and file watching"
```

---

### Task 12: Popover UI — sessions, accounts, footer

**Files:**
- Create: `Sources/ClaudeStatusBar/PopoverView.swift`, `Sources/ClaudeStatusBar/SessionsSection.swift`, `Sources/ClaudeStatusBar/AccountsSection.swift`
- Modify: `Sources/ClaudeStatusBar/ClaudeStatusBarApp.swift` (swap the placeholder popover for `PopoverView`)

**Interfaces:**
- Consumes: `AppState` (Task 11); `SessionRecord`, `MenuBarText.elapsed` (Tasks 5, 10); `Account` (Task 4); `AccountUsageState`, `Freshness` (Task 9); `UsageLevel`, `level(for:yellowAt:redAt:)` (Task 3); `ISO8601` not needed here.
- Produces: `PopoverView(appState:)` — the full popover. Task 13 adds the real `SettingsLink` behavior; here the Settings… button opens the standard Settings scene via `SettingsLink` already (the Settings scene itself lands in Task 13 — until then the button shows an empty window, acceptable mid-plan state).

No unit tests: pure SwiftUI rendering over already-tested models. Test cycle = `swift build` + manual smoke.

- [ ] **Step 1: Implement the sessions section**

`Sources/ClaudeStatusBar/SessionsSection.swift`:

```swift
import SwiftUI
import StatusBarCore

struct SessionsSection: View {
    let sessions: [SessionRecord]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions").font(.caption).foregroundStyle(.secondary)
            if sessions.isEmpty {
                Text("No active Claude Code sessions")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(sessions, id: \.sessionId) { session in
                    HStack {
                        Text(projectName(session.cwd)).fontWeight(.medium)
                        Spacer()
                        Text(stateText(session)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func projectName(_ cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    private func stateText(_ session: SessionRecord) -> String {
        let elapsed = session.busySince.map {
            " · " + MenuBarText.elapsed(now.timeIntervalSince($0))
        } ?? ""
        switch session.state {
        case .idle: return "Idle"
        case .thinking: return "Thinking\(elapsed)"
        case .waiting: return "Waiting for you"
        case .tool: return "\(session.label ?? "Working")\(elapsed)"
        }
    }
}
```

- [ ] **Step 2: Implement the accounts section**

`Sources/ClaudeStatusBar/AccountsSection.swift`:

```swift
import SwiftUI
import StatusBarCore

struct AccountsSection: View {
    let accounts: [Account]
    let states: [String: AccountUsageState]
    let yellowAt: Double
    let redAt: Double
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accounts").font(.caption).foregroundStyle(.secondary)
            if accounts.isEmpty {
                Text("No Claude account found — log in with cux or Claude Code")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { account in
                    AccountRow(account: account, state: states[account.id],
                               yellowAt: yellowAt, redAt: redAt, now: now)
                }
            }
        }
    }
}

private struct AccountRow: View {
    let account: Account
    let state: AccountUsageState?
    let yellowAt: Double
    let redAt: Double
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(account.alias ?? account.email ?? account.id)
                    .fontWeight(account.isActive ? .bold : .regular)
                if account.alias != nil, let email = account.email {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
                if account.isActive {
                    Text("active").font(.caption2).padding(.horizontal, 4)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
                Spacer()
                if state?.needsRelogin == true {
                    Label("re-login needed", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            if let snapshot = state?.snapshot {
                UsageBar(title: "5h", window: snapshot.fiveHour,
                         yellowAt: yellowAt, redAt: redAt, now: now)
                UsageBar(title: "7d", window: snapshot.sevenDay,
                         yellowAt: yellowAt, redAt: redAt, now: now)
            } else {
                Text("No usage data").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(state?.freshness == .fresh ? 1.0 : 0.5)
    }
}

private struct UsageBar: View {
    let title: String
    let window: UsageWindow?
    let yellowAt: Double
    let redAt: Double
    let now: Date

    var body: some View {
        if let window {
            HStack(spacing: 6) {
                Text(title).font(.caption2.monospaced()).frame(width: 18, alignment: .leading)
                ProgressView(value: min(window.utilization, 100), total: 100)
                    .tint(color)
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
                if let resetsAt = window.resetsAt, resetsAt > now {
                    Text("resets in \(MenuBarText.elapsed(resetsAt.timeIntervalSince(now)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var color: Color {
        switch UsageLevel.level(for: window?.utilization ?? 0, yellowAt: yellowAt, redAt: redAt) {
        case .green: return .green
        case .yellow: return .yellow
        case .red: return .red
        }
    }
}
```

- [ ] **Step 3: Implement the popover container and wire it in**

`Sources/ClaudeStatusBar/PopoverView.swift`:

```swift
import SwiftUI
import StatusBarCore

struct PopoverView: View {
    let appState: AppState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                SessionsSection(sessions: appState.sessions, now: context.date)
                Divider()
                AccountsSection(accounts: appState.accounts,
                                states: appState.usageStore.states,
                                yellowAt: appState.yellowAt, redAt: appState.redAt,
                                now: context.date)
                Divider()
                HStack {
                    Button("Refresh") {
                        Task { await appState.refreshUsageNow() }
                    }
                    Spacer()
                    SettingsLink { Text("Settings…") }
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(width: 320)
        }
    }
}
```

In `ClaudeStatusBarApp.swift`, replace the placeholder `VStack` inside `MenuBarExtra { ... }` with:

```swift
            PopoverView(appState: appState)
```

- [ ] **Step 4: Build and smoke-test**

Run: `swift build && swift test`
Expected: builds clean, all tests still pass.

Manual smoke: `swift run ClaudeStatusBar`, click the icon. Expected: Sessions section (empty-state text if no live session), one block per cux account with 5h/7d bars and percentages, active account bolded with an `active` capsule, stale accounts at 50 % opacity, footer buttons work (Settings… opens an empty window until Task 13 — expected). Start a Claude Code session with hooks installed (Task 7 binary + manual settings entry, or wait for Task 13's installer) to see a live session row.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar
git commit -m "feat: add popover with sessions, per-account usage bars, footer"
```

---

### Task 13: Settings — store, window, launch-at-login, hook install UI

**Files:**
- Create: `Sources/StatusBarCore/Settings/SettingsStore.swift`, `Sources/StatusBarCore/Hooks/HookLocator.swift`, `Sources/ClaudeStatusBar/SettingsView.swift`
- Modify: `Sources/ClaudeStatusBar/AppState.swift` (constants → SettingsStore), `Sources/ClaudeStatusBar/ClaudeStatusBarApp.swift` (add `Settings` scene), `Sources/ClaudeStatusBar/PopoverView.swift` (respect hidden accounts)
- Test: `Tests/StatusBarCoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `DisplayStyle` (Task 10); `HookInstaller` (Task 8); `AppState` (Task 11); `Account` (Task 4).
- Produces:
  - `SettingsStore` (`@Observable @MainActor final class`, in StatusBarCore — Observation is not a UI import): `init(defaults: UserDefaults = .standard)`; properties (key = property name, with defaults): `showUsageOnBar: Bool` (true), `displayStyleRaw: String` ("full") + computed `displayStyle: DisplayStyle` falling back to `.full` on unknown raw values, `pollMinutes: Int` (5), `yellowAt: Double` (50), `redAt: Double` (80), `hiddenAccounts: [String]` ([], holds `Account.id`s). Every set persists immediately via `didSet`.
  - `defaultHookBinary(appExecutable: URL?) -> URL?` — sibling `claude-status-hook` of the app executable; nil in un-bundled contexts.
  - `SettingsView(appState:settings:)` — 4 tabs: General / Thresholds / Accounts / Claude Code.
  - `AppState` gains `settings: SettingsStore` and `visibleAccounts: [Account]`; the Task 11 constants become settings-backed computed properties **with the same names**, so `MenuBarLabelView`/popover code keeps compiling unchanged.

- [ ] **Step 1: Write the failing tests**

`Tests/StatusBarCoreTests/SettingsStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

@MainActor @Suite struct SettingsStoreTests {
    private func makeDefaults() -> UserDefaults {
        let name = "settings-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func defaults() {
        let store = SettingsStore(defaults: makeDefaults())
        #expect(store.showUsageOnBar == true)
        #expect(store.displayStyle == .full)
        #expect(store.pollMinutes == 5)
        #expect(store.yellowAt == 50)
        #expect(store.redAt == 80)
        #expect(store.hiddenAccounts.isEmpty)
    }

    @Test func persistsAcrossInstances() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.showUsageOnBar = false
        store.displayStyle = .percent
        store.pollMinutes = 15
        store.yellowAt = 40
        store.redAt = 90
        store.hiddenAccounts = ["slot-2"]

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.showUsageOnBar == false)
        #expect(reloaded.displayStyle == .percent)
        #expect(reloaded.pollMinutes == 15)
        #expect(reloaded.yellowAt == 40)
        #expect(reloaded.redAt == 90)
        #expect(reloaded.hiddenAccounts == ["slot-2"])
    }

    @Test func unknownDisplayStyleFallsBackToFull() {
        let defaults = makeDefaults()
        defaults.set("hologram", forKey: "displayStyleRaw")
        #expect(SettingsStore(defaults: defaults).displayStyle == .full)
    }
}

@Suite struct HookLocatorTests {
    @Test func hookBinarySitsNextToAppExecutable() {
        let app = URL(fileURLWithPath: "/Applications/ClaudeStatusBar.app/Contents/MacOS/ClaudeStatusBar")
        #expect(defaultHookBinary(appExecutable: app)?.path
                == "/Applications/ClaudeStatusBar.app/Contents/MacOS/claude-status-hook")
        #expect(defaultHookBinary(appExecutable: nil) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SettingsStoreTests`
Expected: COMPILE ERROR — `cannot find 'SettingsStore' in scope`.

- [ ] **Step 3: Implement store and locator**

`Sources/StatusBarCore/Settings/SettingsStore.swift`:

```swift
import Foundation
import Observation

/// All user preferences. Each property persists on set; adding a future
/// setting = add one property + one line in init (spec: extensible settings).
@Observable @MainActor
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    public var showUsageOnBar: Bool {
        didSet { defaults.set(showUsageOnBar, forKey: "showUsageOnBar") }
    }
    public var displayStyleRaw: String {
        didSet { defaults.set(displayStyleRaw, forKey: "displayStyleRaw") }
    }
    public var pollMinutes: Int {
        didSet { defaults.set(pollMinutes, forKey: "pollMinutes") }
    }
    public var yellowAt: Double {
        didSet { defaults.set(yellowAt, forKey: "yellowAt") }
    }
    public var redAt: Double {
        didSet { defaults.set(redAt, forKey: "redAt") }
    }
    public var hiddenAccounts: [String] {
        didSet { defaults.set(hiddenAccounts, forKey: "hiddenAccounts") }
    }

    public var displayStyle: DisplayStyle {
        get { DisplayStyle(rawValue: displayStyleRaw) ?? .full }
        set { displayStyleRaw = newValue.rawValue }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showUsageOnBar = defaults.object(forKey: "showUsageOnBar") as? Bool ?? true
        displayStyleRaw = defaults.string(forKey: "displayStyleRaw") ?? DisplayStyle.full.rawValue
        pollMinutes = defaults.object(forKey: "pollMinutes") as? Int ?? 5
        yellowAt = defaults.object(forKey: "yellowAt") as? Double ?? 50
        redAt = defaults.object(forKey: "redAt") as? Double ?? 80
        hiddenAccounts = defaults.stringArray(forKey: "hiddenAccounts") ?? []
    }
}
```

`Sources/StatusBarCore/Hooks/HookLocator.swift`:

```swift
import Foundation

/// The hook binary ships inside the app bundle next to the main executable.
public func defaultHookBinary(appExecutable: URL?) -> URL? {
    appExecutable?.deletingLastPathComponent().appendingPathComponent("claude-status-hook")
}
```

Run: `swift test` — Expected: PASS (all tests, including the 5 new ones).

- [ ] **Step 4: Rewire AppState onto SettingsStore**

In `Sources/ClaudeStatusBar/AppState.swift`, replace the constants block

```swift
    // Settings constants until Task 13 wires SettingsStore.
    let pollMinutes = 5
    let yellowAt: Double = 50
    let redAt: Double = 80
    let displayStyle: DisplayStyle = .full
    let showUsageOnBar = true
```

with

```swift
    let settings: SettingsStore
    var pollMinutes: Int { settings.pollMinutes }
    var yellowAt: Double { settings.yellowAt }
    var redAt: Double { settings.redAt }
    var displayStyle: DisplayStyle { settings.displayStyle }
    var showUsageOnBar: Bool { settings.showUsageOnBar }
    var visibleAccounts: [Account] {
        accounts.filter { !settings.hiddenAccounts.contains($0.id) }
    }
```

and change init to

```swift
    init(paths: AppPaths = AppPaths(), settings: SettingsStore = SettingsStore()) {
        self.paths = paths
        self.settings = settings
        self.usageStore = UsageStore(fetcher: UsageClient(), cacheFile: paths.usageCacheFile)
        self.currentVerb = ThinkingVerbs.all[0]
        self.currentVerb = verbCycler.next()
    }
```

In `PopoverView.swift`, pass `appState.visibleAccounts` to `AccountsSection` instead of `appState.accounts`.

Run: `swift build` — Expected: clean build.

- [ ] **Step 5: Implement the Settings window**

`Sources/ClaudeStatusBar/SettingsView.swift`:

```swift
import SwiftUI
import ServiceManagement
import StatusBarCore

struct SettingsView: View {
    let appState: AppState
    @Bindable var settings: SettingsStore

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ThresholdsTab(settings: settings)
                .tabItem { Label("Thresholds", systemImage: "gauge") }
            AccountsTab(appState: appState, settings: settings)
                .tabItem { Label("Accounts", systemImage: "person.2") }
            ClaudeCodeTab()
                .tabItem { Label("Claude Code", systemImage: "terminal") }
        }
        .frame(width: 440)
        .padding(.bottom, 8)
    }
}

private struct GeneralTab: View {
    @Bindable var settings: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        // Fails under `swift run` — SMAppService needs an installed bundle.
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Show usage on menu bar", isOn: $settings.showUsageOnBar)
            Picker("Display style", selection: $settings.displayStyle) {
                Text("Icon only").tag(DisplayStyle.iconOnly)
                Text("Icon + %").tag(DisplayStyle.percent)
                Text("Full").tag(DisplayStyle.full)
            }
            Picker("Usage poll interval", selection: $settings.pollMinutes) {
                Text("1 min").tag(1)
                Text("5 min").tag(5)
                Text("15 min").tag(15)
            }
        }
        .padding(20)
        .alert("Launch at login failed", isPresented: .constant(loginError != nil)) {
            Button("OK") { loginError = nil }
        } message: {
            Text(loginError ?? "")
        }
    }
}

private struct ThresholdsTab: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Slider(value: $settings.yellowAt, in: 10...90, step: 5) {
                Text("Yellow from \(Int(settings.yellowAt))%")
            }
            Slider(value: $settings.redAt, in: 20...100, step: 5) {
                Text("Red from \(Int(settings.redAt))%")
            }
            if settings.redAt <= settings.yellowAt {
                Text("Red threshold should be above yellow")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(20)
    }
}

private struct AccountsTab: View {
    let appState: AppState
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            if appState.accounts.isEmpty {
                Text("No Claude account found").foregroundStyle(.secondary)
            }
            ForEach(appState.accounts) { account in
                Toggle(title(for: account), isOn: binding(for: account.id))
            }
        }
        .padding(20)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.hiddenAccounts.contains(id) },
            set: { visible in
                if visible {
                    settings.hiddenAccounts.removeAll { $0 == id }
                } else if !settings.hiddenAccounts.contains(id) {
                    settings.hiddenAccounts.append(id)
                }
            })
    }

    private func title(for account: Account) -> String {
        switch (account.alias, account.email) {
        case let (alias?, email?): return "\(alias) — \(email)"
        case let (alias?, nil): return alias
        case let (nil, email?): return email
        default: return account.id
        }
    }
}

private struct ClaudeCodeTab: View {
    @State private var installed: Bool?
    @State private var errorMessage: String?

    private var installer: HookInstaller {
        HookInstaller(settingsFile: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json"))
    }
    private var binary: URL? { defaultHookBinary(appExecutable: Bundle.main.executableURL) }

    var body: some View {
        Form {
            LabeledContent("Hook status") {
                switch installed {
                case true: Text("Installed").foregroundStyle(.green)
                case false: Text("Not installed").foregroundStyle(.secondary)
                default: Text("Unknown").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Install") { mutate { try $0.install(binaryPath: $1) } }
                    .disabled(installed == true)
                Button("Remove") { mutate { installer, _ in try installer.uninstall() } }
                    .disabled(installed != true)
            }
            Text("Adds claude-status-hook entries to ~/.claude/settings.json "
                 + "(a timestamped backup is written first).")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        guard let binary else { installed = nil; return }
        installed = try? installer.status(binaryPath: binary.path)
    }

    private func mutate(_ action: (HookInstaller, String) throws -> Void) {
        guard let binary else {
            errorMessage = "Hook binary not found next to the app executable."
            return
        }
        do {
            try action(installer, binary.path)
            errorMessage = nil
        } catch {
            errorMessage = "Could not update settings.json: \(error.localizedDescription)"
        }
        refresh()
    }
}
```

In `ClaudeStatusBarApp.swift`, add a `Settings` scene after the `MenuBarExtra` scene (inside `body`):

```swift
        Settings {
            SettingsView(appState: appState, settings: appState.settings)
        }
```

- [ ] **Step 6: Build, test, smoke-test**

Run: `swift build && swift test`
Expected: clean build, all tests pass.

Manual smoke: `swift run ClaudeStatusBar` → popover → Settings…. Expected: 4 tabs render; toggling "Show usage on menu bar" updates the bar immediately; hiding an account removes it from the popover; Thresholds sliders recolor the bars; Claude Code tab shows "Not installed" with a working Install (points at the debug binary path — fine for smoke); launch-at-login shows the error alert under `swift run` (expected — needs the installed `.app` from Task 15).

- [ ] **Step 7: Commit**

```bash
git add Sources/StatusBarCore/Settings Sources/StatusBarCore/Hooks/HookLocator.swift Sources/ClaudeStatusBar Tests
git commit -m "feat: add settings window backed by persistent SettingsStore"
```

---

### Task 14: Clawd artwork — download, convert, attribute

**Files:**
- Create: `Sources/ClaudeStatusBar/Resources/clawd/{idle,thinking,notification,typing,building,debugger,carrying}.png`, `LICENSE.clawd-tank`

**Interfaces:**
- Consumes: `ClawdIcon` raw values (Task 11) — the PNG basenames MUST match them exactly.
- Produces: the resource bundle images `MenuBarLabelView` loads at runtime (until now it fell back to SF Symbols).

No unit tests — assets task. Verification = build + visual smoke.

- [ ] **Step 1: Download the 7 Clawd webp frames**

The artwork is MIT (from clawd-tank, re-hosted in the KDE repo). Downloading art assets is allowed; code is not copied.

```bash
cd /Users/ser/scatola/jobs/projects/claude-status-bar-macos
mkdir -p /tmp/clawd
for name in idle thinking notification typing building debugger carrying; do
  curl -fsSL -o "/tmp/clawd/$name.webp" \
    "https://raw.githubusercontent.com/vntrungld/claude-status-bar-kde/main/package/contents/icons/clawd/$name.webp"
done
ls -la /tmp/clawd
```

Expected: 7 `.webp` files, each a few KB. If any 404s, list the directory via the GitHub API to find the real filenames (`gh api repos/vntrungld/claude-status-bar-kde/contents/package/contents/icons/clawd --jq '.[].name'`) and map the closest names to our `ClawdIcon` cases — the raw values in Task 11 are ours; only the downloaded source names may differ.

- [ ] **Step 2: Convert to PNG (first frame) into the resource dir**

```bash
mkdir -p Sources/ClaudeStatusBar/Resources/clawd
for name in idle thinking notification typing building debugger carrying; do
  sips -s format png "/tmp/clawd/$name.webp" \
    --out "Sources/ClaudeStatusBar/Resources/clawd/$name.png"
done
ls Sources/ClaudeStatusBar/Resources/clawd
```

Expected: 7 PNGs. (`sips` takes the first frame of an animated webp — v1 shows static icons; animation is a v2 candidate.)

- [ ] **Step 3: Write the attribution file**

`LICENSE.clawd-tank`:

```
The Clawd artwork in Sources/ClaudeStatusBar/Resources/clawd/ originates from
the clawd-tank project (https://github.com/marciogranzotto/clawd-tank) by
Marcio Granzotto Rodrigues, distributed under the MIT License, and was
obtained via https://github.com/vntrungld/claude-status-bar-kde.

MIT License

Copyright (c) 2024 Marcio Granzotto Rodrigues

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Before committing, verify the copyright line against the upstream LICENSE (`curl -fsSL https://raw.githubusercontent.com/marciogranzotto/clawd-tank/main/LICENSE`) and copy the year/name from there verbatim if they differ.

- [ ] **Step 4: Build and smoke-test the real icons**

Run: `swift build && swift run ClaudeStatusBar`
Expected: menu bar now shows the Clawd PNG (not the SF Symbol fallback). Trigger a state change (touch a fixture session file under `CLAUDE_STATUS_BAR_HOME` or just verify idle) and confirm the icon swaps.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusBar/Resources/clawd LICENSE.clawd-tank
git commit -m "feat: bundle Clawd artwork with clawd-tank MIT attribution"
```

---

### Task 15: Packaging — .app bundle, DMG, README, end-to-end check

**Files:**
- Create: `scripts/make-app.sh`, `README.md`, `LICENSE` (MIT, project's own)
- Modify: `Makefile` (add `app` and `dmg` targets)

**Interfaces:**
- Consumes: release binaries `ClaudeStatusBar` + `claude-status-hook` (`swift build -c release`); SwiftPM resource bundle `claude-status-bar-macos_ClaudeStatusBar.bundle`; `defaultHookBinary` expects the hook binary as a **sibling of the app executable** in `Contents/MacOS/` (Task 13).
- Produces: `dist/ClaudeStatusBar.app`, `dist/ClaudeStatusBar.dmg`.

- [ ] **Step 1: Write the bundling script**

`scripts/make-app.sh`:

```bash
#!/bin/bash
# Assemble dist/ClaudeStatusBar.app from SwiftPM release binaries.
# No Xcode required — plist + codesign only need Command Line Tools.
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP="dist/ClaudeStatusBar.app"
BIN=".build/release"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/ClaudeStatusBar" "$APP/Contents/MacOS/"
cp "$BIN/claude-status-hook" "$APP/Contents/MacOS/"

# SwiftPM resource bundle (Clawd PNGs). Bundle.module resolves it next to
# the executable first, but .app convention is Contents/Resources — copy to
# both to be safe across SwiftPM versions.
BUNDLE="$BIN/claude-status-bar-macos_ClaudeStatusBar.bundle"
if [ -d "$BUNDLE" ]; then
  cp -R "$BUNDLE" "$APP/Contents/Resources/"
  cp -R "$BUNDLE" "$APP/Contents/MacOS/"
else
  echo "warning: resource bundle not found at $BUNDLE" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.juzser.ClaudeStatusBar</string>
    <key>CFBundleName</key>
    <string>ClaudeStatusBar</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeStatusBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License. Clawd artwork © clawd-tank (MIT).</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP (version $VERSION)"
```

```bash
chmod +x scripts/make-app.sh
```

- [ ] **Step 2: Add Makefile targets**

Append to `Makefile` (recipe lines use REAL TABS):

```make
app:
	bash scripts/make-app.sh

dmg: app
	rm -f dist/ClaudeStatusBar.dmg
	hdiutil create -volname ClaudeStatusBar -srcfolder dist/ClaudeStatusBar.app \
		-ov -format UDZO dist/ClaudeStatusBar.dmg
```

- [ ] **Step 3: Build the app and DMG**

Run: `make app && make dmg`
Expected: `Built dist/ClaudeStatusBar.app (version 0.1.0)`; `hdiutil` prints `created: .../dist/ClaudeStatusBar.dmg`. Verify:

```bash
codesign --verify --verbose dist/ClaudeStatusBar.app
ls dist/ClaudeStatusBar.app/Contents/MacOS
```

Expected: `valid on disk`; both `ClaudeStatusBar` and `claude-status-hook` listed. Add `dist/` to `.gitignore` if not already there.

- [ ] **Step 4: Write LICENSE and README**

`LICENSE`: standard MIT text, `Copyright (c) 2026 juzser`.

`README.md`:

```markdown
# Claude Status Bar for macOS

Native macOS menu bar app showing Claude usage and Claude Code activity at a
glance. A clean-room Swift port of the idea behind
[claude-status-bar-kde](https://github.com/vntrungld/claude-status-bar-kde),
with multi-account support.

## Features

- **Usage at a glance** — 5-hour and 7-day utilization for the active Claude
  account in the menu bar, color-coded (green / yellow ≥50% / red ≥80%,
  configurable).
- **Multi-account** — discovers every account managed by
  [cux](https://github.com/junjiangao/cux) under `~/.cux` (falls back to
  `~/.claude/.credentials.json`); per-account usage bars in the popover.
- **Claude Code activity** — Clawd shows what your sessions are doing right
  now (thinking, editing, running…), with playful verbs and elapsed timers,
  driven by Claude Code hooks + file watching (no polling loop).
- **Settings** — display style, poll interval, thresholds, per-account
  visibility, launch at login, hook install/remove.

## Install

Download `ClaudeStatusBar.dmg` from Releases, drag to Applications, launch.
The app lives in the menu bar only (no Dock icon).

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

## License

MIT. Clawd artwork from
[clawd-tank](https://github.com/marciogranzotto/clawd-tank) (MIT) — see
`LICENSE.clawd-tank`.
```

Before committing, verify the cux URL above points at the operator's actual cux tool; if it is not public, drop the link and keep the plain word "cux".

- [ ] **Step 5: End-to-end manual verification checklist**

Run the installed app (`open dist/ClaudeStatusBar.app`) and walk through:

1. Menu bar shows Clawd icon (+ usage text if accounts exist and `showUsageOnBar`).
2. Popover opens on click: sessions empty state or live sessions; accounts with bars; footer buttons work.
3. Settings → Claude Code → Install; verify `~/.claude/settings.json` gained hook entries pointing INTO the .app bundle, and a backup file exists next to it.
4. Run any Claude Code prompt in a terminal; menu bar flips to a thinking verb, then tool labels with elapsed time; Stop returns it to idle.
5. Settings → General → Launch at login toggles without error (works now that it's an installed bundle).
6. Settings → Claude Code → Remove; verify our entries are gone and foreign hooks (if any) survived.
7. Quit from the popover footer.

Record any failure as a bug to fix before the release commit — do not ship with a failing checklist item.

- [ ] **Step 6: Commit**

```bash
git add scripts/make-app.sh Makefile README.md LICENSE .gitignore
git commit -m "feat: package .app and DMG via make-app.sh; add README and MIT license"
```

---

## Execution notes

- Tasks run strictly in order; each leaves `swift test` green and the tree committed.
- Task 11's settings constants are intentionally temporary (replaced in Task 13) — documented there so the mid-plan state is not "fixed" prematurely.
- Task 12's `SettingsLink` opens an empty window until Task 13 lands — acceptable mid-plan state.
- Manual smoke steps require a GUI session; when executing via subagents, the subagent runs the build/test commands and defers GUI verification to the human checkpoints.








