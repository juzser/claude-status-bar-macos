import Foundation
import StatusBarCore

// Claude Code hook entry point: `claude-status-hook <EventName>` with the
// JSON payload on stdin. Must NEVER block or fail Claude Code: every error
// path falls through to a silent exit 0, and nothing is ever printed.
func run() {
    let eventName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    guard let event = HookEvent.parse(eventName: eventName, payload: payload) else { return }

    do {
        let paths = AppPaths()
        try paths.ensureDirs()
        let file = paths.sessionsDir.appendingPathComponent("\(event.sessionId).json")
        let current = (try? Data(contentsOf: file)).flatMap { try? SessionRecord.decode($0) }
        guard let next = SessionReducer.reduce(current, event: event, now: Date()),
              next != current else { return }
        try AtomicFile.write(next.encoded(), to: file)
    } catch {
        // Swallow everything — the hook must not disturb Claude Code.
    }
}

run()
exit(0)
