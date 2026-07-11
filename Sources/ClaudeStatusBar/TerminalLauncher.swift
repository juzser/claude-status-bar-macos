import AppKit

/// Runs an interactive shell command in the user's terminal by opening a
/// `.command` file — the one route that needs no Automation (AppleEvents)
/// TCC grant, unlike scripting Terminal via osascript. Login flows are
/// interactive (browser hand-off, paste-a-code), so they can't run headless
/// inside the app.
enum TerminalLauncher {
    static func run(_ command: String) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-status-bar-login.command")
        let script = "#!/bin/zsh\n\(command)\n"
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            NSSound.beep()
        }
    }
}
