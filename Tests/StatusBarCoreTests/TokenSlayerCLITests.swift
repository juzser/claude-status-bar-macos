import Foundation
import Testing
@testable import StatusBarCore

@Suite struct TokenSlayerCLITests {
    private static let accountsJSON = """
    {"schema":"accounts@1","active":"work",
     "accounts":[{"index":1,"name":"work","alias":null,"email":null,"org_uuid":null,
                  "uuid":null,"plan":null,"active":true,"state":"active","usage":null}]}
    """

    private static let sessionsJSON = """
    {"schema":"sessions@1","sessions":[{"session_id":"a","billed_account":"work"}]}
    """

    // MARK: - Binary resolution

    @Test func resolvesStaticCandidateWhenExecutable() async {
        let cli = TokenSlayerCLI()
        let path = await cli.resolveBinary(staticCandidate: "/bin/ls", dynamicResolve: { "should-not-run" })
        #expect(path == "/bin/ls")
    }

    @Test func fallsBackToDynamicResolveWhenStaticCandidateMissing() async {
        let cli = TokenSlayerCLI()
        let path = await cli.resolveBinary(
            staticCandidate: "/definitely/not/a/real/path-xyz",
            dynamicResolve: { "/bin/ls" }
        )
        #expect(path == "/bin/ls")
    }

    @Test func returnsNilWhenNeitherCandidateResolves() async {
        let cli = TokenSlayerCLI()
        let path = await cli.resolveBinary(
            staticCandidate: "/definitely/not/a/real/path-xyz",
            dynamicResolve: { nil }
        )
        #expect(path == nil)
    }

    @Test func cachesResolutionAcrossCalls() async {
        let cli = TokenSlayerCLI()
        var dynamicCallCount = 0
        let first = await cli.resolveBinary(staticCandidate: "/nope", dynamicResolve: {
            dynamicCallCount += 1
            return "/bin/ls"
        })
        let second = await cli.resolveBinary(staticCandidate: "/nope", dynamicResolve: {
            dynamicCallCount += 1
            return "/bin/ls"
        })
        #expect(first == "/bin/ls")
        #expect(second == "/bin/ls")
        #expect(dynamicCallCount == 1)
    }

    // MARK: - listAccounts / sessions (via injected runner)

    @Test func listAccountsDecodesSuccessfulRunnerOutput() async {
        let cli = TokenSlayerCLI()
        let result = await cli.listAccounts(binaryPath: "/fake/token-slayer", live: false) { _, _, _ in
            .success(Self.accountsJSON)
        }
        switch result {
        case .success(let doc):
            #expect(doc.accounts.first?.name == "work")
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
    }

    @Test func listAccountsUsesStatusSubcommandWhenLive() async {
        let cli = TokenSlayerCLI()
        var seenArguments: [String] = []
        _ = await cli.listAccounts(binaryPath: "/fake/token-slayer", live: true) { _, arguments, _ in
            seenArguments = arguments
            return .success(Self.accountsJSON)
        }
        #expect(seenArguments == ["status", "--json"])
    }

    @Test func listAccountsUsesListSubcommandWhenNotLive() async {
        let cli = TokenSlayerCLI()
        var seenArguments: [String] = []
        _ = await cli.listAccounts(binaryPath: "/fake/token-slayer", live: false) { _, arguments, _ in
            seenArguments = arguments
            return .success(Self.accountsJSON)
        }
        #expect(seenArguments == ["list", "--json"])
    }

    @Test func listAccountsSurfacesRunnerFailureMessage() async {
        let cli = TokenSlayerCLI()
        let result = await cli.listAccounts(binaryPath: "/fake/token-slayer", live: false) { _, _, _ in
            .failure(message: "Error: boom", exitCode: 1)
        }
        switch result {
        case .success:
            Issue.record("expected failure")
        case .failure(.commandFailed(let message)):
            #expect(message == "Error: boom")
        case .failure(let other):
            Issue.record("expected .commandFailed, got \(other)")
        }
    }

    @Test func listAccountsReturnsInvalidOutputForUnparsableJSON() async {
        let cli = TokenSlayerCLI()
        let result = await cli.listAccounts(binaryPath: "/fake/token-slayer", live: false) { _, _, _ in
            .success("not json")
        }
        switch result {
        case .success:
            Issue.record("expected failure")
        case .failure(.invalidOutput):
            break // expected
        case .failure(let other):
            Issue.record("expected .invalidOutput, got \(other)")
        }
    }

    @Test func sessionsDecodesSuccessfulRunnerOutput() async {
        let cli = TokenSlayerCLI()
        let result = await cli.sessions(binaryPath: "/fake/token-slayer") { _, arguments, _ in
            #expect(arguments == ["sessions", "--json"])
            return .success(Self.sessionsJSON)
        }
        switch result {
        case .success(let doc):
            #expect(doc.sessions.first?.sessionId == "a")
        case .failure(let error):
            Issue.record("expected success, got \(error)")
        }
    }

    // MARK: - switchAccount

    @Test func switchAccountSucceedsOnZeroExitCode() async {
        let cli = TokenSlayerCLI()
        var seenArguments: [String] = []
        let result = await cli.switchAccount(target: "work", binaryPath: "/fake/token-slayer") { _, arguments, _ in
            seenArguments = arguments
            return .success("Switched to work")
        }
        #expect(seenArguments == ["switch", "work"])
        switch result {
        case .success: break
        case .failure(let error): Issue.record("expected success, got \(error)")
        }
    }

    @Test func switchAccountNeverUsesForceSwitch() async {
        let cli = TokenSlayerCLI()
        var seenArguments: [String] = []
        _ = await cli.switchAccount(target: "work", binaryPath: "/fake/token-slayer") { _, arguments, _ in
            seenArguments = arguments
            return .success("Switched to work")
        }
        #expect(!seenArguments.contains("force-switch"))
    }

    @Test func switchAccountSurfacesStderrMessageOnFailure() async {
        let cli = TokenSlayerCLI()
        let result = await cli.switchAccount(target: "nonexistent-target-xyz", binaryPath: "/fake/token-slayer") { _, _, _ in
            .failure(message: "Error: nonexistent-target-xyz", exitCode: 1)
        }
        switch result {
        case .success:
            Issue.record("expected failure")
        case .failure(.commandFailed(let message)):
            #expect(message == "Error: nonexistent-target-xyz")
        case .failure(let other):
            Issue.record("expected .commandFailed, got \(other)")
        }
    }

    // MARK: - binary missing

    @Test func listAccountsReturnsBinaryNotFoundWhenPathIsNil() async {
        let cli = TokenSlayerCLI()
        let result = await cli.listAccounts(binaryPath: nil, live: false) { _, _, _ in
            Issue.record("runner should not be invoked when binaryPath is nil")
            return .success(Self.accountsJSON)
        }
        switch result {
        case .success:
            Issue.record("expected failure")
        case .failure(.binaryNotFound):
            break // expected
        case .failure(let other):
            Issue.record("expected .binaryNotFound, got \(other)")
        }
    }
}

/// Exercises the real `Process`-spawning runner directly (not via an
/// injected closure) — the only place in this feature that actually shells
/// out, so it's the one place worth a real-subprocess test.
@Suite struct TokenSlayerDefaultRunnerTests {
    @Test func succeedsAndCapturesStdout() async {
        let outcome = await TokenSlayerCLI.defaultRunner("/bin/echo", ["hello"], 5)
        switch outcome {
        case .success(let stdout):
            #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        case .failure(let message, let exitCode):
            Issue.record("expected success, got \(message) (\(exitCode))")
        }
    }

    @Test func reportsNonZeroExitAsFailure() async {
        let outcome = await TokenSlayerCLI.defaultRunner("/usr/bin/false", [], 5)
        switch outcome {
        case .success:
            Issue.record("expected failure")
        case .failure(_, let exitCode):
            #expect(exitCode != 0)
        }
    }

    @Test func timesOutLongRunningProcess() async {
        let start = Date()
        let outcome = await TokenSlayerCLI.defaultRunner("/bin/sleep", ["5"], 0.2)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 4)
        switch outcome {
        case .success:
            Issue.record("expected timeout failure")
        case .failure:
            break // expected
        }
    }
}
