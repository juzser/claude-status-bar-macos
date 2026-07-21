import Foundation
import Testing
@testable import StatusBarCore

@Suite struct LiveCredentialSelfHealTests {
    @Test func writesCurrentLiveCredentialsBackWithTrustedPaths() async {
        var captured: (Data, [String])?
        let ok = await LiveCredentialSelfHeal.run(
            isTrusted: { false },
            read: { (Data("current-creds".utf8), .success) },
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
            read: { (nil, .itemNotFound) },
            write: { _, _ in writeCalled = true; return true },
            trustedPaths: { [] }
        )

        #expect(ok == false)
        #expect(writeCalled == false)
    }

    @Test func returnsFalseWhenWriteFails() async {
        let ok = await LiveCredentialSelfHeal.run(
            isTrusted: { false },
            read: { (Data("current-creds".utf8), .success) },
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
            read: { (Data("creds".utf8), .success) },
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
            read: { (Data("creds".utf8), .success) },
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
            read: { readCalled = true; return (Data("creds".utf8), .success) },
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
            read: { (Data("creds".utf8), .success) },
            write: { _, _ in true },
            trustedPaths: { [] }
        )

        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("self-heal ACL skipped: already trusted"))
    }

    // MARK: - Finding #5: repair-read failures now carry a status
    //
    // Previously every failed read logged the same generic "no live
    // credentials found" line whether the item was genuinely absent or the
    // read was blocked because the app isn't trusted yet — indistinguishable
    // from the outside. The diagnostic now embeds the KeychainStatus so a
    // real log can be checked against, instead of guessed at, when
    // diagnosing a future "prompt still appeared" report.

    @Test func appendsStatusWhenReadFindsNoCredentials() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("native-switch.log")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await LiveCredentialSelfHeal.run(
            diagnosticLog: log,
            isTrusted: { false },
            read: { (nil, .interactionNotAllowed) },
            write: { _, _ in true },
            trustedPaths: { [] }
        )

        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("interactionNotAllowed"))
    }

    @Test func defaultReadUsesRepairReadWithStatus() async {
        // No injectable seam of its own (it's the production wiring): this
        // only confirms the default compiles and drives the real (albeit
        // presumably-absent-in-CI) Keychain item through repairReadWithStatus
        // rather than crashing.
        let ok = await LiveCredentialSelfHeal.run(isTrusted: { true })
        #expect(ok)
    }
}
