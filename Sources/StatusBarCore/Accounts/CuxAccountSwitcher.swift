import Foundation

/// Runs `cux switch <slot>` to flip the active cux slot, headlessly.
///
/// Unlike the relogin flow (`ReloginCommand` + `TerminalLauncher`), a plain
/// switch needs no browser hand-off — `cux switch` just rewrites
/// `~/.cux/state.json`'s `activeSlot` and returns. That makes it safe to run
/// as a background subprocess exactly like `CuxRefresher` does for
/// `cux usage refresh`.
public actor CuxAccountSwitcher {
    public static let timeout: TimeInterval = 10

    private let candidates: [String]
    private let isExecutable: @Sendable (String) -> Bool
    private let run: @Sendable (String, [String]) async -> Bool

    public init(candidates: [String] = CuxRefresher.binaryCandidates,
                isExecutable: @escaping @Sendable (String) -> Bool = {
                    FileManager.default.isExecutableFile(atPath: $0)
                },
                run: @escaping @Sendable (String, [String]) async -> Bool = {
                    await CuxAccountSwitcher.invoke(binary: $0, arguments: $1,
                                                    timeout: CuxAccountSwitcher.timeout)
                }) {
        self.candidates = candidates
        self.isExecutable = isExecutable
        self.run = run
    }

    /// Runs `cux switch <slot>`. Returns false if no candidate binary is
    /// executable or the process exits non-zero.
    public func switchTo(slot: Int) async -> Bool {
        guard let binary = candidates.first(where: isExecutable) else { return false }
        return await run(binary, ["switch", String(slot)])
    }

    /// Runs `<binary> <arguments>`, discarding output. Returns true only on
    /// exit status 0. Terminates the process if it outlives `timeout`
    /// (terminate() still fires the termination handler, so the continuation
    /// is resumed exactly once).
    public static func invoke(binary: String, arguments: [String], timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}
