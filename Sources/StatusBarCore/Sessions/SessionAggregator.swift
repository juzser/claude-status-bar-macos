import Foundation

public enum SessionAggregator {
    /// Sessions not updated within this window are considered dead and hidden.
    public static let staleAfter: TimeInterval = 900

    public static func loadSessions(from dir: URL, now: Date) -> [SessionRecord] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name -> SessionRecord? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                      let record = try? SessionRecord.decode(data) else { return nil }
                return now.timeIntervalSince(record.updatedAt) <= staleAfter ? record : nil
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public static func displayState(_ sessions: [SessionRecord]) -> SessionRecord? {
        sessions.max { lhs, rhs in
            if lhs.state.priority != rhs.state.priority {
                return lhs.state.priority < rhs.state.priority
            }
            return lhs.updatedAt < rhs.updatedAt
        }
    }
}

extension SessionState {
    /// Busy states outrank waiting: waiting is every open tab's resting
    /// state, so ranking it on top would permanently mask live work
    /// whenever more than one session exists.
    var priority: Int {
        switch self {
        case .tool: return 3
        case .thinking: return 2
        case .waiting: return 1
        case .idle: return 0
        }
    }
}
