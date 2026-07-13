import Foundation

public struct HookEvent: Sendable {
    public let name: String
    public let sessionId: String
    public let cwd: String?
    public let toolName: String?
    public let transcriptPath: String?

    private static let allowedIdCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    /// argv[1] (eventName) wins over the payload's hook_event_name.
    /// Returns nil for malformed payloads or unsafe session ids —
    /// the id is used as a filename, so anything outside [A-Za-z0-9_-] is rejected.
    public static func parse(eventName: String?, payload: Data) -> HookEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        guard let name = eventName ?? (obj["hook_event_name"] as? String), !name.isEmpty else {
            return nil
        }
        guard let id = obj["session_id"] as? String, !id.isEmpty,
              id.unicodeScalars.allSatisfy(allowedIdCharacters.contains) else {
            return nil
        }
        return HookEvent(name: name, sessionId: id,
                         cwd: obj["cwd"] as? String,
                         toolName: obj["tool_name"] as? String,
                         transcriptPath: obj["transcript_path"] as? String)
    }
}

public enum ToolLabels {
    public static func label(for tool: String) -> String {
        switch tool {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing"
        case "Bash": return "Running"
        case "Read": return "Reading"
        case "Grep", "Glob": return "Searching"
        case "WebFetch", "WebSearch": return "Browsing"
        case "Task", "Agent": return "Delegating"
        default: return tool.prefix(1).uppercased() + tool.dropFirst()
        }
    }
}
