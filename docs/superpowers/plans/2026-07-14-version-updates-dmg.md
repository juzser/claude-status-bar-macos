# Version Display, Check for Updates, and DMG Applications Shortcut Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the app's version in Settings, let the user check GitHub for a newer release (automatically once per launch/day, and on demand), and make `make dmg` stage an `/Applications` symlink alongside the app for drag-and-drop install.

**Architecture:** A new `Updates` module in `StatusBarCore` (`ReleaseInfo` model, `GitHubReleaseClient` network client, `UpdateChecker` rate-limited actor) mirrors the existing `Usage` module's `UsageSnapshot`/`UsageClient`/`CuxRefresher` trio exactly. `AppState` owns one `UpdateChecker` and a `updateAvailable: ReleaseInfo?` published property, wired into its existing `Task`-loop startup pattern. `SettingsView` gets a new `AboutTab`; `PopoverView` gets a one-line indicator. Separately, `scripts/make-dmg.sh` (new) stages a temp directory with the `.app` and an `/Applications` symlink before calling `hdiutil create`, and the `Makefile`'s `dmg` target is reduced to invoking it.

**Tech Stack:** Swift 6 tools / `.v5` language mode, SwiftPM (no Xcode project), `swift-testing` `exact: 0.12.0`, `URLSession` + `URLProtocol` stubbing for network tests, bash for the DMG script.

## Global Constraints

- Feature branch → PR into `main` → CI (`swift test` + hook integration test) must pass → owner review and merge. Never push directly to `main`. (`CLAUDE.md`)
- New logic goes in `StatusBarCore` with a matching test file (`Tests/StatusBarCoreTests/`, one file per source file); `ClaudeStatusBar`/`ClaudeStatusHook` stay thin with no tests of their own. (`CLAUDE.md`)
- `swift-testing` is pinned at `exact: "0.12.0"` — only `@Test`/`@Suite`/`#expect`/`#require` API available at that version is usable, no newer swift-testing features. (`CLAUDE.md`)
- No in-app auto-download or self-replacing update installation — on finding a newer release the app only notifies and links out via `NSWorkspace.shared.open(_:)` to the GitHub release page. (spec Decision 4 / Out of scope)
- No persisting "last update check" across app restarts — GitHub's unauthenticated 60 req/hour rate limit comfortably covers a once-a-day background check plus manual clicks. (spec Decision 3 / Out of scope)
- No menu-bar icon badge for available updates — the indicator appears only in the About tab and as a small line in the popover, never composited into the menu-bar `NSImage`. (spec Decision 5 / Out of scope)
- No styled/branded DMG installer window — no background image, no AppleScript-driven Finder icon positioning, just the `.app` and a plain `/Applications` symlink staged side by side. (spec Decision 6 / Out of scope)
- No change to how `VERSION` is set for the `.app` bundle — `scripts/make-app.sh`'s `VERSION="${VERSION:-0.1.2}"` default stays manual. (spec Out of scope)
- Network/parse failures for update checks are swallowed to `nil` the same way `CuxRefresher.refreshIfNeeded` swallows CLI failures — update checks are a nice-to-have background signal, never a user-facing error state. (spec Error handling)
- `make app` and `make dmg` must never be run by the implementing agent — both end in an interactive native Keychain signing prompt (`scripts/ensure-signing-identity.sh` / `codesign`) that only the human user can approve, and a prior background run of `make app` hung indefinitely on `codesign`. Verification of `scripts/make-dmg.sh` is limited to `bash -n` syntax checks and code review; the actual DMG build and drag-and-drop behavior is left for the user to verify by running `make dmg` themselves.

---

### Task 1: `ReleaseInfo` model and parsing

**Files:**
- Create: `Sources/StatusBarCore/Updates/ReleaseInfo.swift`
- Test: `Tests/StatusBarCoreTests/ReleaseInfoTests.swift`

**Interfaces:**
- Consumes: nothing (leaf model).
- Produces: `public struct ReleaseInfo: Codable, Equatable, Sendable { public let tagName: String; public let htmlURL: URL }` with `public init(tagName:htmlURL:)` and `public static func parse(_ data: Data) -> ReleaseInfo?`. Task 2 (`GitHubReleaseClient`) and Task 3 (`UpdateChecker`) both consume this type.

- [ ] **Step 1: Write the failing test file**

Create `Tests/StatusBarCoreTests/ReleaseInfoTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

@Suite("ReleaseInfo")
struct ReleaseInfoTests {
    @Test("parses a well-formed GitHub release response")
    func parsesGoodResponse() {
        let json = Data(#"""
        {"tag_name":"v0.1.3","html_url":"https://github.com/juzser/claude-status-bar-macos/releases/tag/v0.1.3","body":"notes"}
        """#.utf8)
        let info = ReleaseInfo.parse(json)
        #expect(info?.tagName == "v0.1.3")
        #expect(info?.htmlURL == URL(string: "https://github.com/juzser/claude-status-bar-macos/releases/tag/v0.1.3"))
    }

    @Test("returns nil when tag_name is missing")
    func missingTagName() {
        let json = Data(#"{"html_url":"https://example.com/release"}"#.utf8)
        #expect(ReleaseInfo.parse(json) == nil)
    }

    @Test("returns nil when tag_name is empty")
    func emptyTagName() {
        let json = Data(#"{"tag_name":"","html_url":"https://example.com/release"}"#.utf8)
        #expect(ReleaseInfo.parse(json) == nil)
    }

    @Test("returns nil when html_url is missing")
    func missingHTMLURL() {
        let json = Data(#"{"tag_name":"v0.1.3"}"#.utf8)
        #expect(ReleaseInfo.parse(json) == nil)
    }

    @Test("returns nil when html_url is not a valid URL string")
    func malformedURL() {
        let json = Data(#"{"tag_name":"v0.1.3","html_url":""}"#.utf8)
        #expect(ReleaseInfo.parse(json) == nil)
    }

    @Test("returns nil for garbage input")
    func garbageInput() {
        #expect(ReleaseInfo.parse(Data("<html>".utf8)) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ReleaseInfoTests`
Expected: FAIL to build — `error: cannot find type 'ReleaseInfo' in scope` (the type doesn't exist yet).

- [ ] **Step 3: Write the implementation**

Create `Sources/StatusBarCore/Updates/ReleaseInfo.swift`:

```swift
import Foundation

public struct ReleaseInfo: Codable, Equatable, Sendable {
    public let tagName: String
    public let htmlURL: URL

    public init(tagName: String, htmlURL: URL) {
        self.tagName = tagName
        self.htmlURL = htmlURL
    }

    /// Tolerant parser for GitHub's /releases/latest response. Only
    /// `tag_name` and `html_url` are required; every other field is ignored.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let tagName = obj["tag_name"] as? String, !tagName.isEmpty else { return nil }
        guard let urlString = obj["html_url"] as? String, let url = URL(string: urlString) else {
            return nil
        }
        return ReleaseInfo(tagName: tagName, htmlURL: url)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ReleaseInfoTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Updates/ReleaseInfo.swift Tests/StatusBarCoreTests/ReleaseInfoTests.swift
git commit -m "Add ReleaseInfo model for GitHub release parsing"
```

---

### Task 2: `GitHubReleaseClient`

**Files:**
- Create: `Sources/StatusBarCore/Updates/GitHubReleaseClient.swift`
- Test: `Tests/StatusBarCoreTests/GitHubReleaseClientTests.swift`

**Interfaces:**
- Consumes: `ReleaseInfo` and `ReleaseInfo.parse(_:)` from Task 1.
- Produces: `public enum ReleaseError: Error, Equatable { case rateLimited, http(Int), network, malformed }`, `public protocol ReleaseFetching: Sendable { func fetchLatest() async throws -> ReleaseInfo }`, `public struct GitHubReleaseClient: ReleaseFetching` with `public init(session: URLSession = .shared)`. Task 3 (`UpdateChecker`) consumes `GitHubReleaseClient().fetchLatest()` as its default `fetch` closure.

- [ ] **Step 1: Write the failing test file**

Create `Tests/StatusBarCoreTests/GitHubReleaseClientTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

/// Global stub for URLProtocol — one handler at a time, hence .serialized.
/// Named distinctly from UsageClientTests' StubURLProtocol to avoid a
/// same-module redeclaration, and to keep the two suites' static handler
/// state from racing (.serialized only serializes within one suite).
final class GitHubStubURLProtocol: URLProtocol {
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

@Suite(.serialized) struct GitHubReleaseClientTests {
    private func makeClient() -> GitHubReleaseClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubStubURLProtocol.self]
        return GitHubReleaseClient(session: URLSession(configuration: config))
    }

    @Test func fetchLatestParsesGoodResponse() async throws {
        GitHubStubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString ==
                     "https://api.github.com/repos/juzser/claude-status-bar-macos/releases/latest")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            return (200, Data(#"""
            {"tag_name":"v0.1.3","html_url":"https://github.com/juzser/claude-status-bar-macos/releases/tag/v0.1.3"}
            """#.utf8))
        }
        let release = try await makeClient().fetchLatest()
        #expect(release.tagName == "v0.1.3")
        #expect(release.htmlURL == URL(string: "https://github.com/juzser/claude-status-bar-macos/releases/tag/v0.1.3"))
    }

    @Test func statusCodesMapToErrors() async {
        for (status, expected) in [(429, ReleaseError.rateLimited),
                                   (500, ReleaseError.http(500))] {
            GitHubStubURLProtocol.handler = { _ in (status, Data()) }
            await #expect(throws: expected) { try await makeClient().fetchLatest() }
        }
    }

    @Test func garbageBodyIsMalformed() async {
        GitHubStubURLProtocol.handler = { _ in (200, Data("<html>".utf8)) }
        await #expect(throws: ReleaseError.malformed) { try await makeClient().fetchLatest() }
    }

    @Test func transportFailureIsNetwork() async {
        GitHubStubURLProtocol.handler = nil  // startLoading fails -> URLError
        await #expect(throws: ReleaseError.network) { try await makeClient().fetchLatest() }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter GitHubReleaseClientTests`
Expected: FAIL to build — `error: cannot find type 'GitHubReleaseClient' in scope` (and `ReleaseError`, `ReleaseFetching` undefined).

- [ ] **Step 3: Write the implementation**

Create `Sources/StatusBarCore/Updates/GitHubReleaseClient.swift`:

```swift
import Foundation

public enum ReleaseError: Error, Equatable {
    case rateLimited
    case http(Int)
    case network
    case malformed
}

public protocol ReleaseFetching: Sendable {
    func fetchLatest() async throws -> ReleaseInfo
}

/// Real client for GET /repos/juzser/claude-status-bar-macos/releases/latest.
/// Unauthenticated — GitHub's public rate limit (60 req/hour per IP) easily
/// covers a once-a-day background check plus occasional manual clicks.
public struct GitHubReleaseClient: ReleaseFetching {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: URL(string:
            "https://api.github.com/repos/juzser/claude-status-bar-macos/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReleaseError.network
        }
        guard let http = response as? HTTPURLResponse else { throw ReleaseError.network }
        switch http.statusCode {
        case 200...299: break
        case 429: throw ReleaseError.rateLimited
        default: throw ReleaseError.http(http.statusCode)
        }
        guard let release = ReleaseInfo.parse(data) else {
            throw ReleaseError.malformed
        }
        return release
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter GitHubReleaseClientTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Updates/GitHubReleaseClient.swift Tests/StatusBarCoreTests/GitHubReleaseClientTests.swift
git commit -m "Add GitHubReleaseClient for fetching the latest GitHub release"
```

---

### Task 3: `UpdateChecker` actor

**Files:**
- Create: `Sources/StatusBarCore/Updates/UpdateChecker.swift`
- Test: `Tests/StatusBarCoreTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: `ReleaseInfo` (Task 1), `GitHubReleaseClient`/`ReleaseFetching` (Task 2, as the default `fetch` closure).
- Produces: `public actor UpdateChecker` with `public static let minInterval: TimeInterval = 86400`, `public init(fetch: @escaping @Sendable () async throws -> ReleaseInfo = { try await GitHubReleaseClient().fetchLatest() })`, `public func checkIfNeeded(currentVersion: String, now: Date = Date()) async -> ReleaseInfo?`, `public func checkNow(currentVersion: String, now: Date = Date()) async -> ReleaseInfo?`, and `public static func isNewer(latestTag: String, currentVersion: String) -> Bool`. Task 5 (`AppState`) consumes all four.

- [ ] **Step 1: Write the failing test file**

Create `Tests/StatusBarCoreTests/UpdateCheckerTests.swift`:

```swift
import Foundation
import Testing
@testable import StatusBarCore

private actor FetchRecorder {
    private(set) var calls = 0
    func record() { calls += 1 }
}

@Suite("UpdateChecker")
struct UpdateCheckerTests {
    @Test("isNewer detects a newer patch version")
    func isNewerTrue() {
        #expect(UpdateChecker.isNewer(latestTag: "v0.1.3", currentVersion: "0.1.2") == true)
    }

    @Test("isNewer is false for an equal version")
    func isNewerEqual() {
        #expect(UpdateChecker.isNewer(latestTag: "v0.1.2", currentVersion: "0.1.2") == false)
    }

    @Test("isNewer is false for an older version")
    func isNewerOlder() {
        #expect(UpdateChecker.isNewer(latestTag: "v0.1.1", currentVersion: "0.1.2") == false)
    }

    @Test("isNewer is false when the latest tag is malformed")
    func isNewerMalformedTag() {
        #expect(UpdateChecker.isNewer(latestTag: "nightly", currentVersion: "0.1.2") == false)
    }

    @Test("isNewer is false when the current version is malformed")
    func isNewerMalformedCurrent() {
        #expect(UpdateChecker.isNewer(latestTag: "v0.1.3", currentVersion: "dev") == false)
    }

    @Test("checkIfNeeded returns the release when it's newer")
    func checkIfNeededReturnsNewer() async {
        let release = ReleaseInfo(tagName: "v0.1.3", htmlURL: URL(string: "https://example.com")!)
        let checker = UpdateChecker(fetch: { release })
        let result = await checker.checkIfNeeded(currentVersion: "0.1.2")
        #expect(result == release)
    }

    @Test("checkIfNeeded returns nil when already up to date")
    func checkIfNeededUpToDate() async {
        let release = ReleaseInfo(tagName: "v0.1.2", htmlURL: URL(string: "https://example.com")!)
        let checker = UpdateChecker(fetch: { release })
        let result = await checker.checkIfNeeded(currentVersion: "0.1.2")
        #expect(result == nil)
    }

    @Test("checkIfNeeded returns nil when fetch throws")
    func checkIfNeededFetchThrows() async {
        struct Boom: Error {}
        let checker = UpdateChecker(fetch: { throw Boom() })
        let result = await checker.checkIfNeeded(currentVersion: "0.1.2")
        #expect(result == nil)
    }

    @Test("checkIfNeeded rate-limits repeat calls inside minInterval, even after a miss")
    func rateLimits() async {
        let recorder = FetchRecorder()
        let release = ReleaseInfo(tagName: "v0.1.3", htmlURL: URL(string: "https://example.com")!)
        let checker = UpdateChecker(fetch: { await recorder.record(); return release })
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        _ = await checker.checkIfNeeded(currentVersion: "0.1.2", now: t0)
        _ = await checker.checkIfNeeded(currentVersion: "0.1.2", now: t0.addingTimeInterval(30))
        #expect(await recorder.calls == 1)
        _ = await checker.checkIfNeeded(currentVersion: "0.1.2",
                                        now: t0.addingTimeInterval(UpdateChecker.minInterval + 1))
        #expect(await recorder.calls == 2)
    }

    @Test("checkNow bypasses the interval gate")
    func checkNowBypassesGate() async {
        let recorder = FetchRecorder()
        let release = ReleaseInfo(tagName: "v0.1.3", htmlURL: URL(string: "https://example.com")!)
        let checker = UpdateChecker(fetch: { await recorder.record(); return release })
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        _ = await checker.checkIfNeeded(currentVersion: "0.1.2", now: t0)
        #expect(await recorder.calls == 1)
        let result = await checker.checkNow(currentVersion: "0.1.2", now: t0.addingTimeInterval(1))
        #expect(await recorder.calls == 2)
        #expect(result == release)
    }

    @Test("checkNow resets the gate so the next automatic check waits the full interval")
    func checkNowResetsGate() async {
        let recorder = FetchRecorder()
        let release = ReleaseInfo(tagName: "v0.1.3", htmlURL: URL(string: "https://example.com")!)
        let checker = UpdateChecker(fetch: { await recorder.record(); return release })
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        _ = await checker.checkNow(currentVersion: "0.1.2", now: t0)
        #expect(await recorder.calls == 1)
        _ = await checker.checkIfNeeded(currentVersion: "0.1.2", now: t0.addingTimeInterval(30))
        #expect(await recorder.calls == 1)
        _ = await checker.checkIfNeeded(currentVersion: "0.1.2",
                                        now: t0.addingTimeInterval(UpdateChecker.minInterval + 1))
        #expect(await recorder.calls == 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter UpdateCheckerTests`
Expected: FAIL to build — `error: cannot find type 'UpdateChecker' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/StatusBarCore/Updates/UpdateChecker.swift`:

```swift
import Foundation

/// Checks GitHub Releases for a version newer than the running app, at most
/// once per `minInterval` in the background — mirrors CuxRefresher's shape.
/// Failures are swallowed: a failed check just means the caller sees `nil`,
/// never a user-facing error.
public actor UpdateChecker {
    public static let minInterval: TimeInterval = 86400

    private let fetch: @Sendable () async throws -> ReleaseInfo
    private var lastAttempt: Date?

    public init(fetch: @escaping @Sendable () async throws -> ReleaseInfo = {
        try await GitHubReleaseClient().fetchLatest()
    }) {
        self.fetch = fetch
    }

    /// Checks at most once per `minInterval`. Returns the latest release
    /// only when it's newer than `currentVersion`; otherwise nil (including
    /// when gated by the interval, on fetch failure, or malformed data).
    public func checkIfNeeded(currentVersion: String, now: Date = Date()) async -> ReleaseInfo? {
        if let last = lastAttempt, now.timeIntervalSince(last) < Self.minInterval { return nil }
        lastAttempt = now
        return await attempt(currentVersion: currentVersion)
    }

    /// Bypasses the interval gate for a manual "Check for Updates" click,
    /// and still resets `lastAttempt` so the next automatic loop iteration
    /// doesn't immediately re-fire.
    public func checkNow(currentVersion: String, now: Date = Date()) async -> ReleaseInfo? {
        lastAttempt = now
        return await attempt(currentVersion: currentVersion)
    }

    private func attempt(currentVersion: String) async -> ReleaseInfo? {
        guard let release = try? await fetch() else { return nil }
        guard Self.isNewer(latestTag: release.tagName, currentVersion: currentVersion) else { return nil }
        return release
    }

    /// Strips a leading "v" and compares X.Y.Z components numerically. A
    /// malformed tag on either side (not exactly three integer components)
    /// returns false rather than crashing or producing a false positive.
    public static func isNewer(latestTag: String, currentVersion: String) -> Bool {
        guard let latest = versionComponents(latestTag),
              let current = versionComponents(currentVersion) else { return false }
        for (l, c) in zip(latest, current) {
            if l != c { return l > c }
        }
        return false
    }

    private static func versionComponents(_ raw: String) -> [Int]? {
        var s = raw
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return numbers
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter UpdateCheckerTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/StatusBarCore/Updates/UpdateChecker.swift Tests/StatusBarCoreTests/UpdateCheckerTests.swift
git commit -m "Add UpdateChecker actor for rate-limited GitHub release checks"
```

---

### Task 4: `AppVersion`

**Files:**
- Create: `Sources/ClaudeStatusBar/AppVersion.swift`

**Interfaces:**
- Consumes: `Bundle.main.infoDictionary`.
- Produces: `enum AppVersion { static var current: String }`. Task 5 (`AppState`) and Task 6 (`SettingsView`'s `AboutTab`) both consume `AppVersion.current`.

`ClaudeStatusBar` is an executable target with no tests of its own (per `CLAUDE.md`), so this task is verified by a full build rather than a test run.

- [ ] **Step 1: Write the implementation**

Create `Sources/ClaudeStatusBar/AppVersion.swift`:

```swift
import Foundation

/// The running app's version, read from Info.plist. Falls back to "dev"
/// under `swift run`/debug, which has no Info.plist.
enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
```

- [ ] **Step 2: Verify the project builds**

Run: `swift build`
Expected: Build succeeds with no errors (this file has no callers yet, so no functional change).

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStatusBar/AppVersion.swift
git commit -m "Add AppVersion for reading the app's bundle version"
```

---

### Task 5: Wire update checking into `AppState`

**Files:**
- Modify: `Sources/ClaudeStatusBar/AppState.swift`

**Interfaces:**
- Consumes: `UpdateChecker`, `UpdateChecker.minInterval` (Task 3), `AppVersion.current` (Task 4).
- Produces: `AppState.updateAvailable: ReleaseInfo?` (read-only outside the class) and `func checkForUpdatesNow() async`. Task 6 (`SettingsView`'s `AboutTab`) and Task 7 (`PopoverView`) both read `appState.updateAvailable`; Task 6 also calls `appState.checkForUpdatesNow()`.

`ClaudeStatusBar` has no tests of its own, so this task is verified by a full build plus a manual smoke check of the existing `swift test` suite (to confirm the `StatusBarCore` dependency still resolves cleanly).

- [ ] **Step 1: Add the new stored properties**

In `Sources/ClaudeStatusBar/AppState.swift`, find:

```swift
    private(set) var currentVerb: String
    private(set) var tick = Date()
    let usageStore: UsageStore
    let paths: AppPaths

    private let cuxRefresher = CuxRefresher()
    private let cuxAccountSwitcher = CuxAccountSwitcher()
    private var verbCycler = VerbCycler()
    private var watcher: DirectoryWatcher?
    private var pollTask: Task<Void, Never>?
    private var reaggregateTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
```

Replace with:

```swift
    private(set) var currentVerb: String
    private(set) var tick = Date()
    private(set) var updateAvailable: ReleaseInfo?
    let usageStore: UsageStore
    let paths: AppPaths

    private let cuxRefresher = CuxRefresher()
    private let cuxAccountSwitcher = CuxAccountSwitcher()
    private let updateChecker = UpdateChecker()
    private var verbCycler = VerbCycler()
    private var watcher: DirectoryWatcher?
    private var pollTask: Task<Void, Never>?
    private var reaggregateTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
```

- [ ] **Step 2: Start the update-check loop in `start()`**

In the same file, find the end of `start()`:

```swift
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let minutes = self?.pollMinutes ?? 5
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
    }
```

Replace with:

```swift
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let minutes = self?.pollMinutes ?? 5
                try? await Task.sleep(for: .seconds(minutes * 60))
            }
        }
        updateCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdates()
                try? await Task.sleep(for: .seconds(Int(UpdateChecker.minInterval)))
            }
        }
    }
```

- [ ] **Step 3: Add `checkForUpdates()` and `checkForUpdatesNow()`**

In the same file, find:

```swift
    func rerollThinkingPhrase() {
        verbCycler.reset()
        currentVerb = verbCycler.next(from: settings.messageStyle.thinking)
    }

    func refreshUsageNow() async {
```

Replace with:

```swift
    func rerollThinkingPhrase() {
        verbCycler.reset()
        currentVerb = verbCycler.next(from: settings.messageStyle.thinking)
    }

    /// Manual "Check for Updates" button: bypasses the background loop's
    /// rate limit. Only overwrites `updateAvailable` when a newer release is
    /// actually found — a failed or up-to-date check leaves it as-is.
    func checkForUpdatesNow() async {
        if let release = await updateChecker.checkNow(currentVersion: AppVersion.current) {
            updateAvailable = release
        }
    }

    private func checkForUpdates() async {
        if let release = await updateChecker.checkIfNeeded(currentVersion: AppVersion.current) {
            updateAvailable = release
        }
    }

    func refreshUsageNow() async {
```

- [ ] **Step 4: Verify the project builds**

Run: `swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 5: Run the full test suite to confirm nothing regressed**

Run: `swift test`
Expected: PASS (all existing tests plus Tasks 1–3's new tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStatusBar/AppState.swift
git commit -m "Wire UpdateChecker into AppState's startup loop"
```

---

### Task 6: `AboutTab` in Settings

**Files:**
- Modify: `Sources/ClaudeStatusBar/SettingsView.swift`

**Interfaces:**
- Consumes: `AppVersion.current` (Task 4), `appState.updateAvailable: ReleaseInfo?` and `appState.checkForUpdatesNow() async` (Task 5).
- Produces: a new `AboutTab` view registered in `SettingsView`'s `TabView`. No later task depends on this one.

- [ ] **Step 1: Add the tab to `SettingsView`'s `TabView`**

In `Sources/ClaudeStatusBar/SettingsView.swift`, find:

```swift
            ClaudeCodeTab()
                .tabItem { Label("Claude Code", systemImage: "terminal") }
        }
        .frame(width: 440)
        .padding(.bottom, 8)
    }
}
```

Replace with:

```swift
            ClaudeCodeTab()
                .tabItem { Label("Claude Code", systemImage: "terminal") }
            AboutTab(appState: appState)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 440)
        .padding(.bottom, 8)
    }
}
```

- [ ] **Step 2: Add the `AboutTab` view**

In the same file, at the end (after the closing brace of `private struct ClaudeCodeTab`), add:

```swift

private struct AboutTab: View {
    let appState: AppState
    @State private var isChecking = false

    var body: some View {
        Form {
            LabeledContent("Version", value: AppVersion.current)
            if let release = appState.updateAvailable {
                Text("Update available: \(release.tagName)")
                    .foregroundStyle(.orange)
                Button("View Release") {
                    NSWorkspace.shared.open(release.htmlURL)
                }
            } else {
                Text("You're up to date").foregroundStyle(.secondary)
            }
            Button("Check for Updates") {
                isChecking = true
                Task {
                    await appState.checkForUpdatesNow()
                    isChecking = false
                }
            }
            .disabled(isChecking)
        }
        .padding(20)
    }
}
```

- [ ] **Step 3: Verify the project builds**

Run: `swift build`
Expected: Build succeeds with no errors. (`NSWorkspace` resolves the same way `PopoverView.swift`'s `NSApp` already does — `import SwiftUI` re-exports AppKit on macOS, so no new import is needed.)

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeStatusBar/SettingsView.swift
git commit -m "Add About tab with version display and Check for Updates button"
```

---

### Task 7: Update indicator in the popover

**Files:**
- Modify: `Sources/ClaudeStatusBar/PopoverView.swift`

**Interfaces:**
- Consumes: `appState.updateAvailable: ReleaseInfo?` (Task 5).
- Produces: nothing consumed by a later task.

- [ ] **Step 1: Add the indicator line**

In `Sources/ClaudeStatusBar/PopoverView.swift`, find:

```swift
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                SessionsSection(sessions: appState.sessions,
                                titles: appState.sessionTitles, now: context.date)
```

Replace with:

```swift
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                if let release = appState.updateAvailable {
                    Text("Update available: \(release.tagName)")
                        .font(.caption).foregroundStyle(.orange)
                }
                SessionsSection(sessions: appState.sessions,
                                titles: appState.sessionTitles, now: context.date)
```

- [ ] **Step 2: Verify the project builds**

Run: `swift build`
Expected: Build succeeds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/ClaudeStatusBar/PopoverView.swift
git commit -m "Show an update-available line in the popover"
```

---

### Task 8: DMG Applications shortcut

**Files:**
- Create: `scripts/make-dmg.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `dist/ClaudeStatusBar.app` (built by `make app` / `scripts/make-app.sh`, unmodified by this plan).
- Produces: `dist/ClaudeStatusBar.dmg` containing the `.app` plus an `/Applications` symlink. No later task depends on this one.

`make dmg` depends on `make app`, which ends in an interactive Keychain-signing `codesign` step the implementing agent must never run (see Global Constraints). This task's verification is therefore limited to shell syntax checking and code review — building and opening the actual DMG is left for the user.

- [ ] **Step 1: Create the DMG staging script**

Create `scripts/make-dmg.sh`:

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

Make it executable:

```bash
chmod +x scripts/make-dmg.sh
```

- [ ] **Step 2: Verify the script's shell syntax**

Run: `bash -n scripts/make-dmg.sh`
Expected: No output, exit code 0 (syntax is valid; this does not execute the script).

- [ ] **Step 3: Update the `Makefile`'s `dmg` target**

In `Makefile`, find:

```makefile
dmg: app
	rm -f dist/ClaudeStatusBar.dmg
	hdiutil create -volname ClaudeStatusBar -srcfolder dist/ClaudeStatusBar.app \
		-ov -format UDZO dist/ClaudeStatusBar.dmg
```

Replace with:

```makefile
dmg: app
	bash scripts/make-dmg.sh
```

- [ ] **Step 4: Commit**

```bash
git add scripts/make-dmg.sh Makefile
git commit -m "Stage an Applications symlink into the DMG for drag-and-drop install"
```

- [ ] **Step 5: Ask the user to verify the DMG manually**

This step cannot be automated by the implementing agent. Ask the user to run `make dmg` themselves (it will prompt for Keychain access via `scripts/ensure-signing-identity.sh` the first time), then confirm that mounting `dist/ClaudeStatusBar.dmg` in Finder shows both `ClaudeStatusBar.app` and an `Applications` shortcut side by side.

---

## Final Verification

- [ ] Run the full suite once more from a clean state: `swift test`
Expected: PASS (all `StatusBarCoreTests`, including the three new suites from Tasks 1–3).
- [ ] Run: `swift build`
Expected: Build succeeds for all three targets.
- [ ] Run: `make hook-test`
Expected: PASS (confirms the `ClaudeStatusBar`/`ClaudeStatusHook` executables still build and the hook integration script still passes — this plan doesn't touch hook code, but `AppState.swift` changes share the build graph).
