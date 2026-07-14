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
