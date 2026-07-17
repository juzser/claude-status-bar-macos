import Foundation
import Testing
@testable import StatusBarCore

@Suite struct LiveCredentialSelfHealTests {
    @Test func writesCurrentLiveCredentialsBackWithTrustedPaths() {
        var captured: (Data, [String])?
        let ok = LiveCredentialSelfHeal.run(
            read: { Data("current-creds".utf8) },
            write: { data, paths in captured = (data, paths); return true },
            trustedPaths: { ["/Applications/ClaudeStatusBar.app", "/opt/homebrew/bin/claude"] }
        )

        #expect(ok)
        #expect(captured?.0 == Data("current-creds".utf8))
        #expect(captured?.1 == ["/Applications/ClaudeStatusBar.app", "/opt/homebrew/bin/claude"])
    }

    @Test func noOpWhenNoLiveCredentialsExistYet() {
        var writeCalled = false
        let ok = LiveCredentialSelfHeal.run(
            read: { nil },
            write: { _, _ in writeCalled = true; return true },
            trustedPaths: { [] }
        )

        #expect(ok == false)
        #expect(writeCalled == false)
    }

    @Test func returnsFalseWhenWriteFails() {
        let ok = LiveCredentialSelfHeal.run(
            read: { Data("current-creds".utf8) },
            write: { _, _ in false },
            trustedPaths: { [] }
        )

        #expect(ok == false)
    }

    @Test func appendsSuccessDiagnostic() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("native-switch.log")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = LiveCredentialSelfHeal.run(
            diagnosticLog: log,
            read: { Data("creds".utf8) },
            write: { _, _ in true },
            trustedPaths: { [] }
        )

        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("self-heal ACL succeeded"))
    }

    @Test func appendsFailureDiagnosticWhenWriteFails() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("native-switch.log")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = LiveCredentialSelfHeal.run(
            diagnosticLog: log,
            read: { Data("creds".utf8) },
            write: { _, _ in false },
            trustedPaths: { [] }
        )

        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("self-heal ACL failed"))
    }
}
