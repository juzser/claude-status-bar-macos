import Foundation
import Security
import Testing
@testable import StatusBarCore

/// A SecTrustedApplication that works regardless of the (possibly
/// nonexistent) path a test injects as "approved": nil requests trust for
/// the calling process itself, which always succeeds. Standing in for
/// `TrustedApplicationGate.defaultMakeTrustedApplication` in tests that
/// verify approved/rejected filtering rather than the real path-to-app
/// conversion (covered separately by the empty-ACL-hole tests).
private func dummyTrustedApplication(_ path: String) -> SecTrustedApplication? {
    var app: SecTrustedApplication?
    SecTrustedApplicationCreateFromPath(nil, &app)
    return app
}

@Suite struct LiveCredentialWriterTests {
    @Test func readDelegatesToInjectedReader() {
        let result = LiveCredentialWriter.read(reader: { service in
            service == LiveCredentialWriter.service ? Data("token".utf8) : nil
        })
        #expect(result == Data("token".utf8))
    }

    @Test func readReturnsNilWhenReaderReturnsNil() {
        #expect(LiveCredentialWriter.read(reader: { _ in nil }) == nil)
    }

    // MARK: - repairRead / repairReadWithStatus
    //
    // Finding #1: LiveCredentialSelfHeal's repair branch used to be dead
    // code because its `read` default routed to the same non-interactive
    // `read()` the trust probe already uses — whenever the probe failed,
    // that read failed identically, so the write/ACL-repair step below it
    // could never run. `repairRead` is the fix: a distinct, deliberately
    // interactive read used *only* from the repair branch, never from any
    // routine/poll path.

    @Test func repairReadDelegatesToInjectedReader() {
        let result = LiveCredentialWriter.repairRead(reader: { service in
            service == LiveCredentialWriter.service ? Data("token".utf8) : nil
        })
        #expect(result == Data("token".utf8))
    }

    @Test func repairReadReturnsNilWhenReaderReturnsNil() {
        #expect(LiveCredentialWriter.repairRead(reader: { _ in nil }) == nil)
    }

    @Test func repairReadWithStatusDelegatesToInjectedReader() {
        let result = LiveCredentialWriter.repairReadWithStatus(reader: { service in
            (service == LiveCredentialWriter.service ? Data("token".utf8) : nil, .success)
        })
        #expect(result.data == Data("token".utf8))
        #expect(result.status == .success)
    }

    @Test func repairReadWithStatusPassesThroughFailureStatus() {
        let result = LiveCredentialWriter.repairReadWithStatus(reader: { _ in (nil, .interactionNotAllowed) })
        #expect(result.data == nil)
        #expect(result.status == .interactionNotAllowed)
    }

    @Test func defaultRepairReaderWithStatusUsesInteractiveKeychainRead() {
        // No injectable seam of its own (it's the production wiring), so
        // this only confirms it compiles and — against a real, presumably
        // absent test service — reports itemNotFound rather than crashing.
        let result = LiveCredentialWriter.defaultInteractiveReaderWithStatus(
            service: "com.claude-status-bar.does-not-exist-test-only")
        #expect(result.data == nil)
    }

    @Test func writePassesDataTrustedPathsAndServiceThrough() {
        var captured: (Data, [String], String)?
        let ok = LiveCredentialWriter.write(Data("token".utf8), trustedPaths: ["/bin/claude"]) { data, paths, service in
            captured = (data, paths, service)
            return true
        }
        #expect(ok)
        #expect(captured?.0 == Data("token".utf8))
        #expect(captured?.1 == ["/bin/claude"])
        #expect(captured?.2 == LiveCredentialWriter.service)
    }

    @Test func writeFailsWhenWriterFails() {
        let ok = LiveCredentialWriter.write(Data(), trustedPaths: []) { _, _, _ in false }
        #expect(ok == false)
    }

    @Test func writeValuePassesDataAndServiceThrough() {
        var captured: (Data, String)?
        let ok = LiveCredentialWriter.writeValue(Data("token".utf8)) { data, service in
            captured = (data, service)
            return true
        }
        #expect(ok)
        #expect(captured?.0 == Data("token".utf8))
        #expect(captured?.1 == LiveCredentialWriter.service)
    }

    @Test func writeValueFailsWhenWriterFails() {
        let ok = LiveCredentialWriter.writeValue(Data()) { _, _ in false }
        #expect(ok == false)
    }

    @Test func trustedPathsDropsNilClaudePath() {
        let paths = LiveCredentialWriter.trustedPaths(thisAppPath: "/Applications/App.app", claudePath: nil)
        #expect(paths == ["/Applications/App.app"])
    }

    @Test func trustedPathsIncludesBothWhenPresent() {
        let paths = LiveCredentialWriter.trustedPaths(thisAppPath: "/Applications/App.app",
                                                       claudePath: "/opt/homebrew/bin/claude")
        #expect(paths == ["/Applications/App.app", "/opt/homebrew/bin/claude"])
    }

    @Test func resolvedClaudePathReturnsFirstExecutableCandidate() {
        let path = LiveCredentialWriter.resolvedClaudePath(
            candidates: ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"],
            isExecutable: { $0 == "/opt/homebrew/bin/claude" }
        )
        #expect(path == "/opt/homebrew/bin/claude")
    }

    @Test func resolvedClaudePathReturnsNilWhenNoCandidateExecutable() {
        let path = LiveCredentialWriter.resolvedClaudePath(candidates: ["/usr/local/bin/claude"],
                                                           isExecutable: { _ in false })
        #expect(path == nil)
    }

    // MARK: - isAlreadyTrusted

    @Test func isAlreadyTrustedDelegatesToInjectedProber() {
        let result = LiveCredentialWriter.isAlreadyTrusted(prober: { service in
            service == LiveCredentialWriter.service
        })
        #expect(result)
    }

    @Test func isAlreadyTrustedReturnsFalseWhenProberFails() {
        #expect(LiveCredentialWriter.isAlreadyTrusted(prober: { _ in false }) == false)
    }

    // MARK: - performWrite

    @Test func performWriteUpdatesInPlaceWhenItemExists() {
        var capturedQuery: [String: Any]?
        var capturedUpdateAttributes: [String: Any]?
        var addCalled = false

        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: [],
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { query, attributes in
                capturedQuery = query as? [String: Any]
                capturedUpdateAttributes = attributes as? [String: Any]
                return errSecSuccess
            },
            add: { _, _ in
                addCalled = true
                return errSecSuccess
            }
        )

        #expect(ok)
        #expect(addCalled == false)
        #expect(capturedQuery?[kSecAttrService as String] as? String == LiveCredentialWriter.service)
        #expect(capturedQuery?[kSecAttrAccount as String] as? String == "ser")
        #expect(capturedQuery?[kSecAttrLabel as String] as? String == LiveCredentialWriter.service)
        #expect(capturedUpdateAttributes?[kSecValueData as String] as? Data == Data("token".utf8))
    }

    /// This write only ever runs from a user-initiated action (self-heal's
    /// repair branch, gated behind its own non-interactive trust probe) —
    /// never from a background poll loop — so it's fine, and in fact
    /// intended, for the underlying `SecItemUpdate`/`SecItemAdd` to be
    /// allowed to prompt if macOS decides it needs to.
    @Test func performWriteSetsExplicitAuthenticationUIAllowPolicy() {
        var capturedUpdateAttributes: [String: Any]?
        _ = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: [],
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { _, attributes in
                capturedUpdateAttributes = attributes as? [String: Any]
                return errSecSuccess
            },
            add: { _, _ in errSecSuccess }
        )
        let authUI = capturedUpdateAttributes?[kSecUseAuthenticationUI as String] as? String
        #expect(authUI == (kSecUseAuthenticationUIAllow as String))
    }

    @Test func performWriteReportsStatusThroughOnStatusCallback() {
        var reported: [KeychainStatus] = []
        _ = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: [],
            service: LiveCredentialWriter.service,
            account: "ser",
            onStatus: { reported.append($0) },
            update: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess }
        )
        #expect(reported == [.success])
    }

    @Test func performWriteFallsBackToAddWhenItemMissing() {
        var capturedAddAttributes: [String: Any]?

        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: [],
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { _, _ in errSecItemNotFound },
            add: { attributes, _ in
                capturedAddAttributes = attributes as? [String: Any]
                return errSecSuccess
            }
        )

        #expect(ok)
        #expect(capturedAddAttributes?[kSecAttrService as String] as? String == LiveCredentialWriter.service)
        #expect(capturedAddAttributes?[kSecAttrAccount as String] as? String == "ser")
        #expect(capturedAddAttributes?[kSecValueData as String] as? Data == Data("token".utf8))
    }

    @Test func performWriteFailsWithoutFallingBackOnOtherUpdateErrors() {
        var addCalled = false

        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: [],
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { _, _ in errSecAuthFailed },
            add: { _, _ in
                addCalled = true
                return errSecSuccess
            }
        )

        #expect(ok == false)
        #expect(addCalled == false)
    }

    @Test func performWriteReturnsFalseWhenAddFallbackFails() {
        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: [],
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { _, _ in errSecItemNotFound },
            add: { _, _ in errSecDuplicateItem }
        )

        #expect(ok == false)
    }

    // MARK: - performWrite + TrustedApplicationGate (SEC-1, task 2)

    /// Site 1 of SEC-1: a rejected path must not become a `SecTrustedApplication`
    /// at all, so the write is refused (zero `update`, zero `add` calls) and
    /// the existing item's ACL is left untouched. Drives a rejection, so it
    /// must pass an explicit `onReject` (nonfunctional clause 9).
    @Test func performWriteRefusesWriteWhenAllTrustedPathsAreRejected() {
        var updateCalls = 0
        var addCalls = 0
        var rejected: [(path: String, reason: String)] = []

        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: ["/tmp/not-signed"],
            service: LiveCredentialWriter.service,
            account: "ser",
            verify: { _ in false },
            onReject: { path, reason in rejected.append((path, reason)) },
            update: { _, _ in updateCalls += 1; return errSecSuccess },
            add: { _, _ in addCalls += 1; return errSecSuccess }
        )

        #expect(ok == false)
        #expect(updateCalls == 0)
        #expect(addCalls == 0)
        #expect(rejected.count == 1)
        #expect(rejected.first?.path == "/tmp/not-signed")
    }

    /// A non-empty list the verifier approves in full is exempt from the
    /// explicit-`onReject` requirement (nonfunctional clause 9): nothing is
    /// rejected, so nothing is diagnosed, and the write proceeds normally.
    @Test func performWriteProceedsWhenAllTrustedPathsAreApproved() {
        var updateCalls = 0
        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: ["/Applications/Claude.app", "/usr/local/bin/claude"],
            service: LiveCredentialWriter.service,
            account: "ser",
            verify: { _ in true },
            makeTrustedApplication: dummyTrustedApplication,
            update: { _, _ in updateCalls += 1; return errSecSuccess },
            add: { _, _ in errSecSuccess }
        )
        #expect(ok)
        #expect(updateCalls == 1)
    }

    /// Per-path filtering (functional clause 3): with a mix of approved and
    /// rejected paths, the write still proceeds using only the approved
    /// subset, and exactly the rejected path is diagnosed.
    @Test func performWriteFiltersRejectedPathsButKeepsApprovedOnes() {
        var updateCalls = 0
        var rejected: [String] = []
        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: ["/good/path", "/bad/path"],
            service: LiveCredentialWriter.service,
            account: "ser",
            verify: { $0 == "/good/path" },
            onReject: { path, _ in rejected.append(path) },
            makeTrustedApplication: dummyTrustedApplication,
            update: { _, _ in updateCalls += 1; return errSecSuccess },
            add: { _, _ in errSecSuccess }
        )
        #expect(ok)
        #expect(updateCalls == 1)
        #expect(rejected == ["/bad/path"])
    }

    // MARK: - Criterion 7: empty-ACL hole closed at the performWrite sink

    /// (7a) An empty `trustedPaths` list writes with no `kSecAttrAccess` key
    /// at all: `SecAccessCreate` is never invoked, and an existing item's
    /// ACL is left exactly as it was.
    @Test func performWriteWithEmptyTrustedPathsOmitsAccessKey() {
        var capturedUpdateAttributes: [String: Any]?
        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: [],
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { _, attributes in
                capturedUpdateAttributes = attributes as? [String: Any]
                return errSecSuccess
            },
            add: { _, _ in errSecSuccess }
        )
        #expect(ok)
        #expect(capturedUpdateAttributes?[kSecAttrAccess as String] == nil)
    }

    /// (7b) A non-empty filtered list where every approved path still fails
    /// to become a `SecTrustedApplication`: refuse the write rather than
    /// call `SecAccessCreate` with an empty array (nonfunctional clause 6).
    @Test func performWriteRefusesWhenApprovedPathsYieldNoTrustedApplication() {
        var updateCalls = 0
        var addCalls = 0
        var rejected: [String] = []
        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: ["/good/path"],
            service: LiveCredentialWriter.service,
            account: "ser",
            verify: { _ in true },
            onReject: { path, _ in rejected.append(path) },
            makeTrustedApplication: { _ in nil },
            update: { _, _ in updateCalls += 1; return errSecSuccess },
            add: { _, _ in addCalls += 1; return errSecSuccess }
        )
        #expect(ok == false)
        #expect(updateCalls == 0)
        #expect(addCalls == 0)
        #expect(rejected == ["/good/path"])
    }

    // MARK: - Criterion 8: composed all-rejected regression via the real diagnostic channel

    /// End-to-end: `TrustedApplicationGate.filter` composed with
    /// `TrustedApplicationGate.rejectionHandler(writingTo:)` (never
    /// `defaultOnReject`, which would touch the real log path) against a
    /// temp file, asserting exactly one tab-separated diagnostic line and
    /// zero update/add calls when every path is rejected.
    @Test func performWriteAllRejectedWritesExactlyOneDiagnosticLine() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gate-diagnostic-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }

        var updateCalls = 0
        var addCalls = 0
        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: ["/tmp/not-signed"],
            service: LiveCredentialWriter.service,
            account: "ser",
            verify: { _ in false },
            onReject: TrustedApplicationGate.rejectionHandler(writingTo: logURL),
            update: { _, _ in updateCalls += 1; return errSecSuccess },
            add: { _, _ in addCalls += 1; return errSecSuccess }
        )

        #expect(ok == false)
        #expect(updateCalls == 0)
        #expect(addCalls == 0)

        let logText = try String(contentsOf: logURL, encoding: .utf8)
        let lines = logText.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].components(separatedBy: "\t").count == 3)
        #expect(logText.contains("/tmp/not-signed"))
    }

    // MARK: - performWriteValue

    @Test func performWriteValueUpdatesInPlaceWhenItemExists() {
        var capturedQuery: [String: Any]?
        var capturedUpdateAttributes: [String: Any]?
        var addCalled = false

        let ok = LiveCredentialWriter.performWriteValue(
            data: Data("token".utf8),
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { query, attributes in
                capturedQuery = query as? [String: Any]
                capturedUpdateAttributes = attributes as? [String: Any]
                return errSecSuccess
            },
            add: { _, _ in
                addCalled = true
                return errSecSuccess
            }
        )

        #expect(ok)
        #expect(addCalled == false)
        #expect(capturedQuery?[kSecAttrService as String] as? String == LiveCredentialWriter.service)
        #expect(capturedQuery?[kSecAttrAccount as String] as? String == "ser")
        #expect(capturedQuery?[kSecAttrLabel as String] as? String == LiveCredentialWriter.service)
        #expect(capturedUpdateAttributes?[kSecValueData as String] as? Data == Data("token".utf8))
        #expect(capturedUpdateAttributes?[kSecAttrAccess as String] == nil)
    }

    /// Same reasoning as `performWriteSetsExplicitAuthenticationUIAllowPolicy`:
    /// value-only writes still only ever run from a user-initiated switch,
    /// never a background poll.
    @Test func performWriteValueSetsExplicitAuthenticationUIAllowPolicy() {
        var capturedUpdateAttributes: [String: Any]?
        _ = LiveCredentialWriter.performWriteValue(
            data: Data("token".utf8),
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { _, attributes in
                capturedUpdateAttributes = attributes as? [String: Any]
                return errSecSuccess
            },
            add: { _, _ in errSecSuccess }
        )
        let authUI = capturedUpdateAttributes?[kSecUseAuthenticationUI as String] as? String
        #expect(authUI == (kSecUseAuthenticationUIAllow as String))
    }

    @Test func performWriteValueReportsStatusThroughOnStatusCallback() {
        var reported: [KeychainStatus] = []
        _ = LiveCredentialWriter.performWriteValue(
            data: Data("token".utf8),
            service: LiveCredentialWriter.service,
            account: "ser",
            onStatus: { reported.append($0) },
            update: { _, _ in errSecItemNotFound },
            add: { _, _ in errSecSuccess }
        )
        #expect(reported == [.itemNotFound, .success])
    }

    @Test func performWriteValueFallsBackToAddWhenItemMissing() {
        var capturedAddAttributes: [String: Any]?

        let ok = LiveCredentialWriter.performWriteValue(
            data: Data("token".utf8),
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { _, _ in errSecItemNotFound },
            add: { attributes, _ in
                capturedAddAttributes = attributes as? [String: Any]
                return errSecSuccess
            }
        )

        #expect(ok)
        #expect(capturedAddAttributes?[kSecAttrService as String] as? String == LiveCredentialWriter.service)
        #expect(capturedAddAttributes?[kSecAttrAccount as String] as? String == "ser")
        #expect(capturedAddAttributes?[kSecValueData as String] as? Data == Data("token".utf8))
        #expect(capturedAddAttributes?[kSecAttrAccess as String] == nil)
    }

    @Test func performWriteValueFailsWithoutFallingBackOnOtherUpdateErrors() {
        var addCalled = false

        let ok = LiveCredentialWriter.performWriteValue(
            data: Data("token".utf8),
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { _, _ in errSecAuthFailed },
            add: { _, _ in
                addCalled = true
                return errSecSuccess
            }
        )

        #expect(ok == false)
        #expect(addCalled == false)
    }

    @Test func performWriteValueReturnsFalseWhenAddFallbackFails() {
        let ok = LiveCredentialWriter.performWriteValue(
            data: Data("token".utf8),
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { _, _ in errSecItemNotFound },
            add: { _, _ in errSecDuplicateItem }
        )

        #expect(ok == false)
    }

    // MARK: - teamIdentifier

    @Test func teamIdentifierParsesTeamIdentifierLineFromStderr() async {
        let result = await LiveCredentialWriter.teamIdentifier(forExecutableAt: "/opt/homebrew/bin/claude") { _, _ in
            LiveCredentialWriter.ShellResult(
                stdout: "",
                stderr: """
                Executable=/opt/homebrew/bin/claude
                Identifier=com.anthropic.claude
                Format=Mach-O thin (arm64)
                TeamIdentifier=ABCDE12345
                Sealed Resources=none
                """,
                exitCode: 0
            )
        }
        #expect(result == "ABCDE12345")
    }

    @Test func teamIdentifierReturnsNilWhenNotSet() async {
        let result = await LiveCredentialWriter.teamIdentifier(forExecutableAt: "/opt/homebrew/bin/claude") { _, _ in
            LiveCredentialWriter.ShellResult(stdout: "", stderr: "TeamIdentifier=not set\n", exitCode: 0)
        }
        #expect(result == nil)
    }

    @Test func teamIdentifierReturnsNilWhenNoTeamIdentifierLine() async {
        let result = await LiveCredentialWriter.teamIdentifier(forExecutableAt: "/opt/homebrew/bin/claude") { _, _ in
            LiveCredentialWriter.ShellResult(stdout: "", stderr: "Executable=/opt/homebrew/bin/claude\nIdentifier=com.anthropic.claude", exitCode: 0)
        }
        #expect(result == nil)
    }

    @Test func teamIdentifierPassesPathThroughToRun() async {
        var capturedArguments: [String]?
        _ = await LiveCredentialWriter.teamIdentifier(forExecutableAt: "/opt/homebrew/bin/claude") { binary, arguments in
            capturedArguments = arguments
            #expect(binary == "/usr/bin/codesign")
            return LiveCredentialWriter.ShellResult(stdout: "", stderr: "", exitCode: 0)
        }
        #expect(capturedArguments?.last == "/opt/homebrew/bin/claude")
    }

    // MARK: - setPartitionList

    @Test func setPartitionListPassesFormattedArgumentsThrough() async {
        var capturedArguments: [String]?
        var capturedBinary: String?
        _ = await LiveCredentialWriter.setPartitionList(
            teamID: "ABCDE12345",
            account: "ser",
            service: LiveCredentialWriter.service
        ) { binary, arguments in
            capturedBinary = binary
            capturedArguments = arguments
            return LiveCredentialWriter.ShellResult(stdout: "", stderr: "", exitCode: 0)
        }
        #expect(capturedBinary == "/usr/bin/security")
        #expect(capturedArguments == [
            "set-generic-password-partition-list",
            "-S", "apple-tool:,apple:,teamid:ABCDE12345",
            "-s", LiveCredentialWriter.service,
            "-a", "ser",
        ])
    }

    @Test func setPartitionListReturnsTrueOnZeroExitCode() async {
        let ok = await LiveCredentialWriter.setPartitionList(teamID: "ABCDE12345", account: "ser") { _, _ in
            LiveCredentialWriter.ShellResult(stdout: "", stderr: "", exitCode: 0)
        }
        #expect(ok)
    }

    @Test func setPartitionListReturnsFalseOnNonzeroExitCode() async {
        let ok = await LiveCredentialWriter.setPartitionList(teamID: "ABCDE12345", account: "ser") { _, _ in
            LiveCredentialWriter.ShellResult(stdout: "", stderr: "some error", exitCode: 1)
        }
        #expect(ok == false)
    }
}
