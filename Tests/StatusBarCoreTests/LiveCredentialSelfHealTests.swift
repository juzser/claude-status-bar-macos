import Foundation
import Testing
@testable import StatusBarCore

@Suite struct LiveCredentialSelfHealTests {
    @Test func writesCurrentLiveCredentialsBackWithTrustedPaths() async {
        var captured: (Data, [String])?
        let ok = await LiveCredentialSelfHeal.run(
            isTrusted: { false },
            read: { Data("current-creds".utf8) },
            write: { data, paths in captured = (data, paths); return true },
            trustedPaths: { ["/Applications/ClaudeStatusBar.app", "/opt/homebrew/bin/claude"] }
        )

        #expect(ok)
        #expect(captured?.0 == Data("current-creds".utf8))
        #expect(captured?.1 == ["/Applications/ClaudeStatusBar.app", "/opt/homebrew/bin/claude"])
    }

    @Test func noOpWhenNoLiveCredentialsExistYet() async {
        var writeCalled = false
        let ok = await LiveCredentialSelfHeal.run(
            isTrusted: { false },
            read: { nil },
            write: { _, _ in writeCalled = true; return true },
            trustedPaths: { [] }
        )

        #expect(ok == false)
        #expect(writeCalled == false)
    }

    @Test func returnsFalseWhenWriteFails() async {
        let ok = await LiveCredentialSelfHeal.run(
            isTrusted: { false },
            read: { Data("current-creds".utf8) },
            write: { _, _ in false },
            trustedPaths: { [] }
        )

        #expect(ok == false)
    }

    @Test func appendsSuccessDiagnostic() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("native-switch.log")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await LiveCredentialSelfHeal.run(
            diagnosticLog: log,
            isTrusted: { false },
            read: { Data("creds".utf8) },
            write: { _, _ in true },
            trustedPaths: { [] }
        )

        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("self-heal ACL succeeded"))
    }

    @Test func appendsFailureDiagnosticWhenWriteFails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("native-switch.log")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await LiveCredentialSelfHeal.run(
            diagnosticLog: log,
            isTrusted: { false },
            read: { Data("creds".utf8) },
            write: { _, _ in false },
            trustedPaths: { [] }
        )

        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("self-heal ACL failed"))
    }

    @Test func skipsReadAndWriteWhenAlreadyTrusted() async {
        var readCalled = false
        var writeCalled = false
        let ok = await LiveCredentialSelfHeal.run(
            isTrusted: { true },
            read: { readCalled = true; return Data("creds".utf8) },
            write: { _, _ in writeCalled = true; return true },
            trustedPaths: { [] }
        )

        #expect(ok)
        #expect(readCalled == false)
        #expect(writeCalled == false)
    }

    @Test func appendsSkippedDiagnosticWhenAlreadyTrusted() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("native-switch.log")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await LiveCredentialSelfHeal.run(
            diagnosticLog: log,
            isTrusted: { true },
            read: { Data("creds".utf8) },
            write: { _, _ in true },
            trustedPaths: { [] }
        )

        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("self-heal ACL skipped: already trusted"))
    }
}
