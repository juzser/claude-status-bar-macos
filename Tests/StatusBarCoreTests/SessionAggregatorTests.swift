import Foundation
import Testing
@testable import StatusBarCore

private func record(id: String, state: SessionState, startedAt: Date,
                    updatedAt: Date) -> SessionRecord {
    SessionRecord(sessionId: id, state: state, label: nil, cwd: "/tmp/\(id)",
                  startedAt: startedAt, busySince: nil, updatedAt: updatedAt)
}

@Suite struct SessionAggregatorTests {
    let now = Date(timeIntervalSince1970: 10_000)

    @Test func loadsLiveSessionsSkippingStaleAndMalformed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let live = record(id: "live", state: .thinking,
                          startedAt: now.addingTimeInterval(-500),
                          updatedAt: now.addingTimeInterval(-10))
        let older = record(id: "older", state: .idle,
                           startedAt: now.addingTimeInterval(-800),
                           updatedAt: now.addingTimeInterval(-899))
        let stale = record(id: "stale", state: .tool,
                           startedAt: now.addingTimeInterval(-5_000),
                           updatedAt: now.addingTimeInterval(-901))
        try AtomicFile.write(live.encoded(), to: dir.appendingPathComponent("live.json"))
        try AtomicFile.write(older.encoded(), to: dir.appendingPathComponent("older.json"))
        try AtomicFile.write(stale.encoded(), to: dir.appendingPathComponent("stale.json"))
        try AtomicFile.write(Data("broken".utf8), to: dir.appendingPathComponent("bad.json"))
        try AtomicFile.write(Data("x".utf8), to: dir.appendingPathComponent("notes.txt"))

        let sessions = SessionAggregator.loadSessions(from: dir, now: now)
        #expect(sessions.map(\.sessionId) == ["older", "live"])  // sorted by startedAt
    }

    @Test func missingDirectoryYieldsEmpty() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        #expect(SessionAggregator.loadSessions(from: dir, now: now).isEmpty)
    }

    @Test func missingDirectoryPruneIsNoOp() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        #expect(SessionAggregator.loadSessions(from: dir, now: Date()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func prunesRecordFileOlderThanRetention() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        let old = record(id: "old", state: .idle,
                         startedAt: now.addingTimeInterval(-SessionAggregator.pruneAfter - 3600),
                         updatedAt: now.addingTimeInterval(-SessionAggregator.pruneAfter - 3600))
        let url = dir.appendingPathComponent("old.json")
        try AtomicFile.write(old.encoded(), to: url)

        _ = SessionAggregator.loadSessions(from: dir, now: now)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func keepsFreshRecordFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        let fresh = record(id: "fresh", state: .idle,
                           startedAt: now.addingTimeInterval(-60),
                           updatedAt: now.addingTimeInterval(-60))
        let url = dir.appendingPathComponent("fresh.json")
        try AtomicFile.write(fresh.encoded(), to: url)

        _ = SessionAggregator.loadSessions(from: dir, now: now)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func prunesMalformedFileOlderThanRetentionByMtime() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        let url = dir.appendingPathComponent("bad.json")
        try AtomicFile.write(Data("broken".utf8), to: url)
        let oldMtime = now.addingTimeInterval(-SessionAggregator.pruneAfter - 3600)
        try FileManager.default.setAttributes([.modificationDate: oldMtime], ofItemAtPath: url.path)

        _ = SessionAggregator.loadSessions(from: dir, now: now)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func keepsFreshMalformedFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()

        // mtime defaults to "now" (just written) — recent, might be mid-write.
        let url = dir.appendingPathComponent("bad.json")
        try AtomicFile.write(Data("broken".utf8), to: url)

        _ = SessionAggregator.loadSessions(from: dir, now: now)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func displayStatePicksByPriority() {
        let idle = record(id: "a", state: .idle, startedAt: now, updatedAt: now)
        let thinking = record(id: "b", state: .thinking, startedAt: now, updatedAt: now)
        let tool = record(id: "c", state: .tool, startedAt: now, updatedAt: now)
        let waiting = record(id: "d", state: .waiting, startedAt: now, updatedAt: now)
        #expect(SessionAggregator.displayState([idle, thinking])?.sessionId == "b")
        #expect(SessionAggregator.displayState([thinking, tool])?.sessionId == "c")
        // Busy beats waiting: with several tabs open, some session is almost
        // always sitting on the user — it must not mask live work.
        #expect(SessionAggregator.displayState([tool, waiting, idle])?.sessionId == "c")
        #expect(SessionAggregator.displayState([thinking, waiting])?.sessionId == "b")
        #expect(SessionAggregator.displayState([idle, waiting])?.sessionId == "d")
        #expect(SessionAggregator.displayState([]) == nil)
    }

    @Test func tieBrokenByMostRecentUpdate() {
        let older = record(id: "old", state: .tool, startedAt: now,
                           updatedAt: now.addingTimeInterval(-60))
        let newer = record(id: "new", state: .tool, startedAt: now, updatedAt: now)
        #expect(SessionAggregator.displayState([older, newer])?.sessionId == "new")
    }
}
