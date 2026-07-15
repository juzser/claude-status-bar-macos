import Foundation
import Testing
@testable import StatusBarCore

@Suite("CuxShellInvoker")
struct CuxShellInvokerTests {
    @Test("resolves PATH the way an interactive shell's rc file would")
    func resolvesPathViaInteractiveShellRC() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cux-shell-invoker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeBinDir = dir.appendingPathComponent("fakebin")
        try FileManager.default.createDirectory(at: fakeBinDir, withIntermediateDirectories: true)
        let interpreter = fakeBinDir.appendingPathComponent("fake-node-test")
        try "#!/bin/sh\nexit 0\n".write(to: interpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: interpreter.path)

        let launcher = dir.appendingPathComponent("fake-cux")
        try "#!/usr/bin/env fake-node-test\n".write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: launcher.path)

        let zdotdir = dir.appendingPathComponent("zdotdir")
        try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        try "export PATH=\"$FAKE_BIN_DIR:$PATH\"\n"
            .write(to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let repairedResult = await CuxShellInvoker.invoke(
            binary: launcher.path, arguments: [], timeout: 5,
            environment: [
                "HOME": zdotdir.path,
                "ZDOTDIR": zdotdir.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "FAKE_BIN_DIR": fakeBinDir.path,
            ])
        #expect(repairedResult == true)

        let emptyHome = dir.appendingPathComponent("empty-home")
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        let unrepairedResult = await CuxShellInvoker.invoke(
            binary: launcher.path, arguments: [], timeout: 5,
            environment: [
                "HOME": emptyHome.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ])
        #expect(unrepairedResult == false)
    }

    @Test("quotes arguments containing spaces so they survive shell parsing")
    func quotesArgumentsWithSpaces() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cux-shell-invoker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let marker = dir.appendingPathComponent("marker.txt")
        let script = dir.appendingPathComponent("capture.sh")
        try "#!/bin/sh\nprintf '%s' \"$1\" > \"\(marker.path)\"\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        let result = await CuxShellInvoker.invoke(
            binary: script.path, arguments: ["hello world"], timeout: 5,
            environment: ["HOME": dir.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(result == true)
        let captured = try String(contentsOf: marker, encoding: .utf8)
        #expect(captured == "hello world")
    }

    @Test("diagnosticLog captures stdout, stderr, and exit code, overwriting on each call")
    func diagnosticLogCapturesOutput() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cux-shell-invoker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("noisy.sh")
        try "#!/bin/sh\necho out-marker\necho err-marker 1>&2\nexit 7\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        // A nonzero exit still returns false from invoke, but the log should
        // still be written — diagnostics matter most on failure.
        let diagnosticLog = dir.appendingPathComponent("diag.log")

        let result = await CuxShellInvoker.invoke(
            binary: script.path, arguments: [], timeout: 5,
            environment: ["HOME": dir.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            diagnosticLog: diagnosticLog)
        #expect(result == false)

        let contents = try String(contentsOf: diagnosticLog, encoding: .utf8)
        #expect(contents.contains("out-marker"))
        #expect(contents.contains("err-marker"))
        #expect(contents.contains("exitCode: 7"))

        // A second, successful call overwrites rather than appends.
        let quiet = dir.appendingPathComponent("quiet.sh")
        try "#!/bin/sh\nexit 0\n".write(to: quiet, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: quiet.path)
        let secondResult = await CuxShellInvoker.invoke(
            binary: quiet.path, arguments: [], timeout: 5,
            environment: ["HOME": dir.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            diagnosticLog: diagnosticLog)
        #expect(secondResult == true)
        let overwritten = try String(contentsOf: diagnosticLog, encoding: .utf8)
        #expect(!overwritten.contains("out-marker"))
        #expect(overwritten.contains("exitCode: 0"))
    }
}
