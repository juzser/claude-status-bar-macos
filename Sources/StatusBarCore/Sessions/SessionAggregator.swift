import Foundation

public enum SessionAggregator {
    /// Sessions not updated within this window are considered dead and hidden.
    public static let staleAfter: TimeInterval = 900
    /// Session files not touched within this window are deleted outright —
    /// distinct from `staleAfter`, which only hides recent-but-idle sessions
    /// from the UI without removing anything. Nothing else ever deletes these
    /// files, so without this the sessions directory grows unboundedly.
    public static let pruneAfter: TimeInterval = 7 * 24 * 3600

    /// Lists live sessions, deleting stale-beyond-`pruneAfter` files along the
    /// way. Piggybacks on the existing per-file read (no extra timer/pass):
    /// a decodable file is prunable by `updatedAt`; a malformed file can't
    /// report that, so it falls back to file mtime — guarding a file that's
    /// merely mid-write (fresh mtime, no valid content yet) from deletion.
    public static func loadSessions(from dir: URL, now: Date) -> [SessionRecord] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var sessions: [SessionRecord] = []
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let record = try? SessionRecord.decode(data) else {
                if isMtimePrunable(url, now: now, fm: fm) {
                    try? fm.removeItem(at: url)
                }
                continue
            }
            if now.timeIntervalSince(record.updatedAt) > pruneAfter {
                // Deleting here (and above) touches the sessions dir, which
                // fires the DirectoryWatcher's `.write` event and re-triggers
                // `reaggregate()` — a harmless, self-terminating extra rescan
                // since the next pass finds nothing left to prune. Known and
                // accepted.
                try? fm.removeItem(at: url)
                continue
            }
            if now.timeIntervalSince(record.updatedAt) <= staleAfter {
                sessions.append(record)
            }
        }
        return sessions.sorted { $0.startedAt < $1.startedAt }
    }

    private static func isMtimePrunable(_ url: URL, now: Date, fm: FileManager) -> Bool {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(mtime) > pruneAfter
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
