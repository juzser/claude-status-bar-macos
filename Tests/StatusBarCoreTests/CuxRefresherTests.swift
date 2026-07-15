import Foundation
import Testing
@testable import StatusBarCore

private func account(slot: Int?, id: String = "acct") -> Account {
    Account(id: id, alias: nil, email: nil, slot: slot, isActive: false,
            oauthURL: URL(fileURLWithPath: "/dev/null"))
}

private actor RunRecorder {
    private(set) var calls: [String] = []
    func record(_ binary: String) { calls.append(binary) }
}

@Suite("CuxRefresher")
struct CuxRefresherTests {
    @Test("runs the CLI when a cux slot account is present")
    func runsForSlotAccounts() async {
        let recorder = RunRecorder()
        let refresher = CuxRefresher(candidates: ["/fake/cux"],
                                     isExecutable: { _ in true },
                                     run: { binary in await recorder.record(binary); return true })
        await refresher.refreshIfNeeded(accounts: [account(slot: 1)])
        #expect(await recorder.calls == ["/fake/cux"])
    }

    @Test("does nothing when no account is cux-managed")
    func skipsWithoutSlotAccounts() async {
        let recorder = RunRecorder()
        let refresher = CuxRefresher(candidates: ["/fake/cux"],
                                     isExecutable: { _ in true },
                                     run: { binary in await recorder.record(binary); return true })
        await refresher.refreshIfNeeded(accounts: [account(slot: nil, id: "default")])
        #expect(await recorder.calls.isEmpty)
    }

    @Test("does nothing when no candidate binary exists")
    func skipsWithoutBinary() async {
        let recorder = RunRecorder()
        let refresher = CuxRefresher(candidates: ["/fake/cux"],
                                     isExecutable: { _ in false },
                                     run: { binary in await recorder.record(binary); return true })
        await refresher.refreshIfNeeded(accounts: [account(slot: 1)])
        #expect(await recorder.calls.isEmpty)
    }

    @Test("uses the first candidate that exists")
    func picksFirstExistingCandidate() async {
        let recorder = RunRecorder()
        let refresher = CuxRefresher(candidates: ["/a/cux", "/b/cux"],
                                     isExecutable: { $0 == "/b/cux" },
                                     run: { binary in await recorder.record(binary); return true })
        await refresher.refreshIfNeeded(accounts: [account(slot: 1)])
        #expect(await recorder.calls == ["/b/cux"])
    }

    @Test("rate-limits repeat runs inside minInterval, even after failure")
    func rateLimits() async {
        let recorder = RunRecorder()
        let refresher = CuxRefresher(candidates: ["/fake/cux"],
                                     isExecutable: { _ in true },
                                     run: { binary in await recorder.record(binary); return false })
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        await refresher.refreshIfNeeded(accounts: [account(slot: 1)], now: t0)
        await refresher.refreshIfNeeded(accounts: [account(slot: 1)],
                                        now: t0.addingTimeInterval(30))
        #expect(await recorder.calls.count == 1)
        await refresher.refreshIfNeeded(accounts: [account(slot: 1)],
                                        now: t0.addingTimeInterval(CuxRefresher.minInterval + 1))
        #expect(await recorder.calls.count == 2)
    }

    @Test("invoke reports exit status and survives a missing binary")
    func invokeRunsRealProcess() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cux-refresher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let ok = dir.appendingPathComponent("ok.sh")
        try "#!/bin/sh\nexit 0\n".write(to: ok, atomically: true, encoding: .utf8)
        let bad = dir.appendingPathComponent("bad.sh")
        try "#!/bin/sh\nexit 1\n".write(to: bad, atomically: true, encoding: .utf8)
        for script in [ok, bad] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: script.path)
        }

        let diagnosticLog = dir.appendingPathComponent("diag.log")
        #expect(await CuxRefresher.invoke(binary: ok.path, timeout: 5,
                                          diagnosticLog: diagnosticLog) == true)
        #expect(await CuxRefresher.invoke(binary: bad.path, timeout: 5,
                                          diagnosticLog: diagnosticLog) == false)
        #expect(await CuxRefresher.invoke(binary: dir.appendingPathComponent("missing").path,
                                          timeout: 5, diagnosticLog: diagnosticLog) == false)
    }

    @Test("invoke kills a hung binary at the timeout")
    func invokeTimesOut() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cux-refresher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let hang = dir.appendingPathComponent("hang.sh")
        try "#!/bin/sh\nsleep 30\n".write(to: hang, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: hang.path)

        // A hermetic HOME (no real ~/.zshrc) keeps interactive zsh startup
        // near-instant. Inheriting the real environment here would let the
        // developer machine's actual ~/.zshrc (nvm hooks etc.) race past
        // this test's short timeout before the hung process even forks,
        // so the kill would target rc-loading helpers instead of the hang.
        let emptyHome = dir.appendingPathComponent("empty-home")
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)

        let started = Date()
        #expect(await CuxRefresher.invoke(
            binary: hang.path, timeout: 0.5,
            environment: ["HOME": emptyHome.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            diagnosticLog: dir.appendingPathComponent("diag.log")) == false)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
