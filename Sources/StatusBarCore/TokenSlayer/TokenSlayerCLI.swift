import Foundation

/// Errors surfaced from a `token-slayer` invocation. `.commandFailed` carries
/// the CLI's own stderr text verbatim (per the contract: failure = plain-text
/// message on stderr + non-zero exit) so callers can show it to the user
/// without inventing their own wording.
public enum TokenSlayerError: Error, Equatable, Sendable {
    case binaryNotFound
    case invalidOutput
    case commandFailed(String)
}

/// Outcome of one subprocess invocation, before JSON decoding — kept
/// separate from `TokenSlayerError` so the runner layer never has to know
/// about JSON at all.
public enum TokenSlayerRunOutcome: Sendable {
    case success(String)
    case failure(message: String, exitCode: Int32)
}

/// Injectable in place of `TokenSlayerCLI.defaultRunner` for tests: `(binary,
/// arguments, timeout) -> outcome`.
public typealias TokenSlayerRunner = @Sendable (String, [String], TimeInterval) async -> TokenSlayerRunOutcome

/// Thin wrapper around the `token-slayer` CLI: resolves the binary once per
/// launch (mirrors `ClaudeBinaryLocator`'s cached-resolution pattern), then
/// exposes typed calls for the three subcommands this app needs. Every call
/// degrades to a typed `Result` failure rather than throwing or hanging —
/// callers are expected to fall back to last-known data on failure, per the
/// "never crash/wedge the UI" requirement.
public actor TokenSlayerCLI {
    public static let shared = TokenSlayerCLI()

    /// The CLI's documented install location. Checked before falling back to
    /// a PATH lookup (a plain string, not a closure, since — unlike
    /// `claude` — there's exactly one well-known path to check first).
    public static let defaultCandidatePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/token-slayer").path

    public static let readTimeout: TimeInterval = 10
    public static let switchTimeout: TimeInterval = 20

    private var hasResolved = false
    private var cachedPath: String?

    public init() {}

    /// Cached for the actor's lifetime: a poll cycle or popover open would
    /// otherwise re-check the filesystem/PATH on every call. A binary
    /// installed mid-session isn't picked up until next launch — the same
    /// tradeoff `ClaudeBinaryLocator` makes.
    public func resolveBinary(
        staticCandidate: String = TokenSlayerCLI.defaultCandidatePath,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        dynamicResolve: () async -> String? = {
            await InteractiveShellRunner.captureOutput(binary: "command", arguments: ["-v", "token-slayer"], timeout: 5)
        }
    ) async -> String? {
        if hasResolved {
            return cachedPath
        }
        let resolved: String?
        if isExecutable(staticCandidate) {
            resolved = staticCandidate
        } else {
            resolved = await dynamicResolve()
        }
        cachedPath = resolved
        hasResolved = true
        return resolved
    }

    /// `live == true` runs `status --json` (refreshes usage, slower); `false`
    /// runs `list --json` (cached, fast) — see the contract's cadence note:
    /// poll cycle uses `status`, popover-open uses `list`.
    public func listAccounts(
        binaryPath: String?,
        live: Bool,
        timeout: TimeInterval = TokenSlayerCLI.readTimeout,
        run: TokenSlayerRunner = TokenSlayerCLI.defaultRunner
    ) async -> Result<SlayerAccountsDoc, TokenSlayerError> {
        guard let binaryPath else { return .failure(.binaryNotFound) }
        let subcommand = live ? "status" : "list"
        return await decode(
            outcome: run(binaryPath, [subcommand, "--json"], timeout),
            parse: SlayerAccountsDoc.parse
        )
    }

    public func sessions(
        binaryPath: String?,
        timeout: TimeInterval = TokenSlayerCLI.readTimeout,
        run: TokenSlayerRunner = TokenSlayerCLI.defaultRunner
    ) async -> Result<SlayerSessionsDoc, TokenSlayerError> {
        guard let binaryPath else { return .failure(.binaryNotFound) }
        return await decode(
            outcome: run(binaryPath, ["sessions", "--json"], timeout),
            parse: SlayerSessionsDoc.parse
        )
    }

    /// `target` is resolved by the CLI itself (integer → index, else alias →
    /// email → name); this app always passes the account's `name`. Never
    /// invokes `force-switch` — only the safety-checked `switch` subcommand.
    public func switchAccount(
        target: String,
        binaryPath: String?,
        timeout: TimeInterval = TokenSlayerCLI.switchTimeout,
        run: TokenSlayerRunner = TokenSlayerCLI.defaultRunner
    ) async -> Result<Void, TokenSlayerError> {
        guard let binaryPath else { return .failure(.binaryNotFound) }
        switch await run(binaryPath, ["switch", target], timeout) {
        case .success:
            return .success(())
        case .failure(let message, _):
            return .failure(.commandFailed(message))
        }
    }

    private func decode<Doc>(
        outcome: TokenSlayerRunOutcome,
        parse: (Data) -> Doc?
    ) async -> Result<Doc, TokenSlayerError> {
        switch outcome {
        case .success(let stdout):
            guard let doc = parse(Data(stdout.utf8)) else { return .failure(.invalidOutput) }
            return .success(doc)
        case .failure(let message, _):
            return .failure(.commandFailed(message))
        }
    }

    /// Guards a `withCheckedContinuation` against being resumed twice —
    /// termination and the timeout fire on different queues and could
    /// otherwise race.
    private final class ResumeGuard: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func resumeOnce(_ body: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return }
            didResume = true
            body()
        }
    }

    /// Direct `Process` spawn by absolute path (no shell), modeled on
    /// `LiveCredentialWriter.defaultRun` — plus a timeout, which that
    /// function deliberately omits (it may need to block on a Keychain
    /// prompt) but every token-slayer call needs, per the "never wedge the
    /// UI" requirement.
    public static let defaultRunner: TokenSlayerRunner = { binary, arguments, timeout in
        await withCheckedContinuation { (continuation: CheckedContinuation<TokenSlayerRunOutcome, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let resumeGuard = ResumeGuard()

            process.terminationHandler = { finished in
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                resumeGuard.resumeOnce {
                    if finished.terminationStatus == 0 {
                        continuation.resume(returning: .success(stdout))
                    } else {
                        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: .failure(
                            message: message.isEmpty
                                ? "token-slayer exited with status \(finished.terminationStatus)"
                                : message,
                            exitCode: finished.terminationStatus
                        ))
                    }
                }
            }

            do {
                try process.run()
            } catch {
                resumeGuard.resumeOnce {
                    continuation.resume(returning: .failure(message: "process.run() failed: \(error)", exitCode: -1))
                }
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumeGuard.resumeOnce {
                    if process.isRunning {
                        process.terminate()
                    }
                    continuation.resume(returning: .failure(
                        message: "token-slayer timed out after \(Int(timeout))s", exitCode: -1
                    ))
                }
            }
        }
    }
}
