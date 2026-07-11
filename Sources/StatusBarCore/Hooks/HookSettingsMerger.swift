import Foundation

/// Pure merge logic for Claude Code's ~/.claude/settings.json hook entries.
/// Works on [String: Any] because settings.json is user-owned free-form JSON:
/// everything we don't understand must round-trip untouched.
public enum HookSettingsMerger {
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse",
        "PostToolUse", "Stop", "Notification",
    ]
    private static let marker = "claude-status-hook"
    private static let matcherEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    public static func install(into settings: [String: Any], binaryPath: String) -> [String: Any] {
        var result = remove(from: settings)  // idempotency: drop any prior entry of ours
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in events {
            // The command runs through a shell; the path must be quoted or an
            // .app renamed to contain a space silently breaks every hook.
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": "\"\(binaryPath)\" \(event)"]]
            ]
            if matcherEvents.contains(event) { entry["matcher"] = "*" }
            var list = hooks[event] as? [[String: Any]] ?? []
            list.append(entry)
            hooks[event] = list
        }
        result["hooks"] = hooks
        return result
    }

    public static func remove(from settings: [String: Any]) -> [String: Any] {
        var result = settings
        guard var hooks = result["hooks"] as? [String: Any] else { return result }
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else { continue }
            let kept = list.filter { !isOurs($0) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooks }
        return result
    }

    public static func isInstalled(_ settings: [String: Any], binaryPath: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { event in
            guard let list = hooks[event] as? [[String: Any]] else { return false }
            return list.contains { entry in
                commands(of: entry).contains { $0.hasPrefix("\"\(binaryPath)\" ") }
            }
        }
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        commands(of: entry).contains { $0.contains(marker) }
    }

    private static func commands(of entry: [String: Any]) -> [String] {
        ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
    }
}
