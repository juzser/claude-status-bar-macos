import Foundation
import Testing
@testable import StatusBarCore

private actor RunRecorder {
    private(set) var calls: [(binary: String, arguments: [String])] = []
    func record(_ binary: String, _ arguments: [String]) { calls.append((binary, arguments)) }
}

@Suite("CuxAccountSwitcher")
struct CuxAccountSwitcherTests {
    @Test("switches to the given slot when a binary is found and the process exits 0")
    func switchesWhenBinaryFoundAndProcessSucceeds() async {
        let recorder = RunRecorder()
        let switcher = CuxAccountSwitcher(candidates: ["/fake/cux"],
                                          isExecutable: { _ in true },
                                          run: { binary, arguments in
                                              await recorder.record(binary, arguments)
                                              return true
                                          })
        let result = await switcher.switchTo(slot: 2)
        #expect(result == true)
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].binary == "/fake/cux")
        #expect(calls[0].arguments == ["switch", "2"])
    }

    @Test("fails when no candidate binary is executable")
    func failsWithoutExecutableBinary() async {
        let recorder = RunRecorder()
        let switcher = CuxAccountSwitcher(candidates: ["/fake/cux"],
                                          isExecutable: { _ in false },
                                          run: { binary, arguments in
                                              await recorder.record(binary, arguments)
                                              return true
                                          })
        let result = await switcher.switchTo(slot: 2)
        #expect(result == false)
        let calls = await recorder.calls
        #expect(calls.isEmpty)
    }

    @Test("fails when the process exits non-zero")
    func failsWhenProcessExitsNonZero() async {
        let switcher = CuxAccountSwitcher(candidates: ["/fake/cux"],
                                          isExecutable: { _ in true },
                                          run: { _, _ in false })
        let result = await switcher.switchTo(slot: 2)
        #expect(result == false)
    }

    @Test("uses the first candidate that exists")
    func picksFirstExistingCandidate() async {
        let recorder = RunRecorder()
        let switcher = CuxAccountSwitcher(candidates: ["/a/cux", "/b/cux"],
                                          isExecutable: { $0 == "/b/cux" },
                                          run: { binary, arguments in
                                              await recorder.record(binary, arguments)
                                              return true
                                          })
        _ = await switcher.switchTo(slot: 3)
        let calls = await recorder.calls
        #expect(calls.map(\.binary) == ["/b/cux"])
    }

    @Test("invoke reports exit status and survives a missing binary")
    func invokeRunsRealProcess() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cux-switcher-\(UUID().uuidString)")
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
        #expect(await CuxAccountSwitcher.invoke(binary: ok.path, arguments: ["switch", "1"],
                                                 timeout: 5, diagnosticLog: diagnosticLog) == true)
        #expect(await CuxAccountSwitcher.invoke(binary: bad.path, arguments: ["switch", "1"],
                                                 timeout: 5, diagnosticLog: diagnosticLog) == false)
        #expect(await CuxAccountSwitcher.invoke(
            binary: dir.appendingPathComponent("missing").path,
            arguments: ["switch", "1"], timeout: 5, diagnosticLog: diagnosticLog) == false)
    }
}
