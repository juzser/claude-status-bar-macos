import Foundation
import Testing
@testable import StatusBarCore

/// Vault counterpart to `LiveCredentialSelfHealTests` — same shape, scoped
/// to one account's backup item instead of the shared live item. Synchronous
/// (no `async`) because, unlike the live item's ACL (which must also trust
/// `claude`'s resolved binary path), the vault is exclusively read/written
/// by this app itself, so there's no `ClaudeBinaryLocator` lookup involved.
@Suite struct AccountVaultSelfHealTests {
    @Test func repairsWhenNotAlreadyTrusted() {
        var captured: (Data, String, [String])?
        let ok = AccountVaultSelfHeal.run(
            accountId: "native-0",
            isTrusted: { _ in false },
            read: { _ in (Data("backup".utf8), .success) },
            write: { data, accountId, paths in captured = (data, accountId, paths); return true },
            trustedPaths: { ["/Applications/ClaudeStatusBar.app"] }
        )

        #expect(ok)
        #expect(captured?.0 == Data("backup".utf8))
        #expect(captured?.1 == "native-0")
        #expect(captured?.2 == ["/Applications/ClaudeStatusBar.app"])
    }

    @Test func skipsReadAndWriteWhenAlreadyTrusted() {
        var readCalled = false
        var writeCalled = false
        let ok = AccountVaultSelfHeal.run(
            accountId: "native-0",
            isTrusted: { _ in true },
            read: { _ in readCalled = true; return (Data("backup".utf8), .success) },
            write: { _, _, _ in writeCalled = true; return true },
            trustedPaths: { [] }
        )

        #expect(ok)
        #expect(readCalled == false)
        #expect(writeCalled == false)
    }

    @Test func noOpWhenNoBackupExistsYet() {
        var writeCalled = false
        let ok = AccountVaultSelfHeal.run(
            accountId: "native-0",
            isTrusted: { _ in false },
            read: { _ in (nil, .itemNotFound) },
            write: { _, _, _ in writeCalled = true; return true },
            trustedPaths: { [] }
        )

        #expect(ok == false)
        #expect(writeCalled == false)
    }

    @Test func returnsFalseWhenWriteFails() {
        let ok = AccountVaultSelfHeal.run(
            accountId: "native-0",
            isTrusted: { _ in false },
            read: { _ in (Data("backup".utf8), .success) },
            write: { _, _, _ in false },
            trustedPaths: { [] }
        )

        #expect(ok == false)
    }

    @Test func passesAccountIdThroughToIsTrustedAndRead() {
        var trustedProbeAccountId: String?
        var readAccountId: String?
        _ = AccountVaultSelfHeal.run(
            accountId: "native-7",
            isTrusted: { accountId in trustedProbeAccountId = accountId; return true },
            read: { accountId in readAccountId = accountId; return (Data(), .success) },
            write: { _, _, _ in true },
            trustedPaths: { [] }
        )

        #expect(trustedProbeAccountId == "native-7")
        // isTrusted short-circuits the read entirely when true, so it's
        // never called — see skipsReadAndWriteWhenAlreadyTrusted above.
        #expect(readAccountId == nil)
    }

    @Test func appendsSuccessDiagnostic() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("native-switch.log")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = AccountVaultSelfHeal.run(
            accountId: "native-0",
            diagnosticLog: log,
            isTrusted: { _ in false },
            read: { _ in (Data("backup".utf8), .success) },
            write: { _, _, _ in true },
            trustedPaths: { [] }
        )

        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("vault self-heal succeeded for native-0"))
    }

    @Test func appendsStatusWhenReadFindsNoBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("native-switch.log")
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = AccountVaultSelfHeal.run(
            accountId: "native-0",
            diagnosticLog: log,
            isTrusted: { _ in false },
            read: { _ in (nil, .interactionNotAllowed) },
            write: { _, _, _ in true },
            trustedPaths: { [] }
        )

        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("interactionNotAllowed"))
    }

    @Test func defaultsCompileAndSkipWhenAlreadyTrusted() {
        // No injectable seam for the defaults themselves (production
        // wiring): confirms they compile and, against a real Keychain, this
        // reports success via the isTrusted-true short-circuit rather than
        // driving a real interactive repair in a test run.
        let ok = AccountVaultSelfHeal.run(accountId: "does-not-exist-test-only", isTrusted: { _ in true })
        #expect(ok)
    }

    private func account(_ id: String, isActive: Bool) -> Account {
        Account(id: id, alias: nil, email: nil, slot: 0, isActive: isActive,
               oauthURL: URL(fileURLWithPath: "/dev/null"))
    }

    /// `usageInputs(_:)`'s per-launch gating (Finding #2's other half):
    /// only inactive accounts ever read the vault (see
    /// `TokenResolution.resolve`), and only those not already attempted this
    /// launch — mirrors `LiveCredentialSelfHeal`'s "once per launch, not on
    /// a timer" reasoning, scoped per-account since accounts can be added
    /// mid-session.
    @Test func accountsNeedingSelfHealExcludesActiveAndAlreadyAttempted() {
        let accounts = [
            account("a", isActive: true),
            account("b", isActive: false),
            account("c", isActive: false),
        ]
        let result = AccountVaultSelfHeal.accountsNeedingSelfHeal(accounts, alreadyAttempted: ["b"])
        #expect(result.map(\.id) == ["c"])
    }

    @Test func accountsNeedingSelfHealReturnsEmptyWhenAllAttemptedOrActive() {
        let accounts = [account("a", isActive: true), account("b", isActive: false)]
        let result = AccountVaultSelfHeal.accountsNeedingSelfHeal(accounts, alreadyAttempted: ["b"])
        #expect(result.isEmpty)
    }
}
