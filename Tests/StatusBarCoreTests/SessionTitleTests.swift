import Foundation
import Testing
@testable import StatusBarCore

@Suite struct SessionTitleTests {
    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("title-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func lastAiTitleWins() throws {
        let url = try write([
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"ai-title","aiTitle":"First title","sessionId":"s"}"#,
            #"{"type":"assistant","message":{"content":[]}}"#,
            #"{"type":"ai-title","aiTitle":"Renamed later","sessionId":"s"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SessionTitle.read(transcript: url) == "Renamed later")
    }

    @Test func noTitleReturnsNil() throws {
        let url = try write([#"{"type":"user","message":{"content":"hi"}}"#])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SessionTitle.read(transcript: url) == nil)
    }

    @Test func missingFileReturnsNil() {
        let gone = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl")
        #expect(SessionTitle.read(transcript: gone) == nil)
    }

    @Test func malformedLinesAreSkipped() throws {
        let url = try write([
            "not json at all",
            #"{"type":"ai-title","aiTitle":"Good title","sessionId":"s"}"#,
            #"{"type":"ai-title","aiTitle":""}"#,  // empty title never wins
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SessionTitle.read(transcript: url) == "Good title")
    }

    @Test func readsOnlyTheTailOfLargeFiles() throws {
        // A title outside the tail window is invisible; the cut's partial
        // first line must not break parsing of the rest.
        var lines = [#"{"type":"ai-title","aiTitle":"Too old","sessionId":"s"}"#]
        lines += Array(repeating: #"{"type":"assistant","message":{"content":"xxxx"}}"#,
                       count: 200)
        lines.append(#"{"type":"ai-title","aiTitle":"Recent","sessionId":"s"}"#)
        let url = try write(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(SessionTitle.read(transcript: url, tailBytes: 2_048) == "Recent")
    }
}
