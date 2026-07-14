import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared subprocess invocation behind `CuxAccountSwitcher.invoke` and
/// `CuxRefresher.invoke`.
///
/// cux is a Node script (`#!/usr/bin/env node`), typically installed via a
/// version manager like nvm, whose PATH setup is sourced only by
/// interactive shell startup files (~/.zshrc). A GUI app launched by
/// LaunchServices inherits only the bare `/usr/bin:/bin:/usr/sbin:/sbin`
/// PATH, under which the shebang's `env node` step can't find `node`.
/// Routing the call through an interactive zsh (`-ilc`) makes the shell
/// resolve `node` itself, exactly as it would in the user's own terminal —
/// the same assumption TerminalLauncher already makes about the user's
/// shell being zsh.
enum CuxShellInvoker {
    /// Runs `<binary> <arguments>` inside an interactive zsh, discarding
    /// output. Returns true only on exit status 0. Terminates the process
    /// if it outlives `timeout` (terminate() still fires the termination
    /// handler, so the continuation is resumed exactly once).
    /// `environment` defaults to nil (inherit the app's own environment,
    /// including whatever HOME LaunchServices set — that's what lets zsh
    /// find the user's real ~/.zshrc); tests override it to point zsh's rc
    /// lookup at a hermetic fixture instead.
    static func invoke(binary: String, arguments: [String], timeout: TimeInterval,
                       environment: [String: String]? = nil) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", command(binary: binary, arguments: arguments)]
            if let environment {
                process.environment = environment
            }
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
            // zsh's shebang chain (env -> node, or a plain script's shell
            // interpreter) can fork further children of its own — e.g. `sh`
            // running a script forks a separate PID for the script's last
            // command rather than exec-ing into it. process.terminate() only
            // signals the single PID Process tracks, so a hang further down
            // the tree would outlive it. Moving the child into its own
            // process group at timeout (so the whole group could be killed
            // at once) doesn't work: setpgid() fails with EACCES once the
            // target has already exec'd, and process.run() only returns
            // after that initial exec into zsh has already happened —
            // confirmed empirically, not just per POSIX docs. Walking the
            // live process tree at timeout and signaling every descendant
            // individually sidesteps that restriction (kill() has no
            // exec-history restriction, unlike setpgid()).
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                for pid in descendantPIDs(of: process.processIdentifier) {
                    kill(pid, SIGTERM)
                }
                process.terminate()
            }
        }
    }

    /// Snapshots the system-wide pid/ppid table via `ps` and returns every
    /// transitive descendant of `pid`, deepest-first order not guaranteed
    /// (callers signal them all, so order doesn't matter).
    private static func descendantPIDs(of pid: pid_t) -> [pid_t] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var childrenByParent: [pid_t: [pid_t]] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let childPID = pid_t(fields[0]), let parentPID = pid_t(fields[1]) else {
                continue
            }
            childrenByParent[parentPID, default: []].append(childPID)
        }

        var result: [pid_t] = []
        var queue = [pid]
        while let current = queue.popLast() {
            let children = childrenByParent[current] ?? []
            result.append(contentsOf: children)
            queue.append(contentsOf: children)
        }
        return result
    }

    private static func command(binary: String, arguments: [String]) -> String {
        ([binary] + arguments).map(quote).joined(separator: " ")
    }

    private static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
