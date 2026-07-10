import Foundation

public enum SessionState: String, Codable, Equatable, Sendable {
    case idle, thinking, tool, waiting
}

public struct SessionRecord: Codable, Equatable, Sendable {
    public var sessionId: String
    public var state: SessionState
    public var label: String?
    public var cwd: String
    public var startedAt: Date
    public var busySince: Date?
    public var updatedAt: Date

    public static func decode(_ data: Data) throws -> SessionRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionRecord.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

public enum SessionReducer {
    /// Applies one hook event. Returns nil when the event is unrecognized
    /// and there is no existing record to preserve.
    public static func reduce(_ current: SessionRecord?, event: HookEvent,
                              now: Date) -> SessionRecord? {
        var record = current ?? SessionRecord(
            sessionId: event.sessionId, state: .idle, label: nil,
            cwd: event.cwd ?? "", startedAt: now, busySince: nil, updatedAt: now)
        if let cwd = event.cwd, !cwd.isEmpty { record.cwd = cwd }
        record.updatedAt = now

        switch event.name {
        case "SessionStart":
            record.state = .idle
            record.label = nil
            record.busySince = nil
            record.startedAt = now
        case "UserPromptSubmit":
            record.state = .thinking
            record.label = nil
            record.busySince = record.busySince ?? now
        case "PreToolUse":
            record.state = .tool
            record.label = event.toolName.map(ToolLabels.label(for:)) ?? "Working"
            record.busySince = record.busySince ?? now
        case "PostToolUse":
            record.state = .thinking
            record.label = nil
        case "Notification":
            record.state = .waiting
        case "Stop":
            record.state = .idle
            record.label = nil
            record.busySince = nil
        default:
            return current
        }
        return record
    }
}
