import Foundation
import Testing
@testable import StatusBarCore

@Suite struct HookEventTests {
    @Test func parsesPayload() throws {
        let payload = Data(#"{"session_id":"abc-123","cwd":"/tmp/p","tool_name":"Bash","hook_event_name":"PreToolUse","transcript_path":"/tmp/t.jsonl"}"#.utf8)
        let event = try #require(HookEvent.parse(eventName: nil, payload: payload))
        #expect(event.name == "PreToolUse")
        #expect(event.sessionId == "abc-123")
        #expect(event.cwd == "/tmp/p")
        #expect(event.toolName == "Bash")
        #expect(event.transcriptPath == "/tmp/t.jsonl")
    }

    @Test func argvNameWinsOverPayload() throws {
        let payload = Data(#"{"session_id":"abc","hook_event_name":"Stop"}"#.utf8)
        let event = try #require(HookEvent.parse(eventName: "PreToolUse", payload: payload))
        #expect(event.name == "PreToolUse")
    }

    @Test func rejectsBadInput() {
        #expect(HookEvent.parse(eventName: "Stop", payload: Data("junk".utf8)) == nil)
        #expect(HookEvent.parse(eventName: "Stop", payload: Data("{}".utf8)) == nil)
        // path traversal in session_id must be rejected — it becomes a filename
        let evil = Data(#"{"session_id":"../../etc/passwd"}"#.utf8)
        #expect(HookEvent.parse(eventName: "Stop", payload: evil) == nil)
        // no event name anywhere
        let noName = Data(#"{"session_id":"abc"}"#.utf8)
        #expect(HookEvent.parse(eventName: nil, payload: noName) == nil)
    }
}

@Suite struct ToolLabelsTests {
    @Test func knownTools() {
        #expect(ToolLabels.label(for: "Edit") == "Editing")
        #expect(ToolLabels.label(for: "Write") == "Editing")
        #expect(ToolLabels.label(for: "MultiEdit") == "Editing")
        #expect(ToolLabels.label(for: "NotebookEdit") == "Editing")
        #expect(ToolLabels.label(for: "Bash") == "Running")
        #expect(ToolLabels.label(for: "Read") == "Reading")
        #expect(ToolLabels.label(for: "Grep") == "Searching")
        #expect(ToolLabels.label(for: "Glob") == "Searching")
        #expect(ToolLabels.label(for: "WebFetch") == "Browsing")
        #expect(ToolLabels.label(for: "WebSearch") == "Browsing")
        #expect(ToolLabels.label(for: "Task") == "Delegating")
        #expect(ToolLabels.label(for: "Agent") == "Delegating")
    }

    @Test func unknownToolIsCapitalized() {
        #expect(ToolLabels.label(for: "mcp__thing") == "Mcp__thing")
    }
}

@Suite struct SessionReducerTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 1_060)
    let t2 = Date(timeIntervalSince1970: 1_120)

    private func event(_ name: String, tool: String? = nil) -> HookEvent {
        let toolPart = tool.map { #","tool_name":"\#($0)""# } ?? ""
        let json = #"{"session_id":"s1","cwd":"/tmp/p"\#(toolPart)}"#
        return HookEvent.parse(eventName: name, payload: Data(json.utf8))!
    }

    @Test func sessionStartCreatesIdle() throws {
        let rec = try #require(SessionReducer.reduce(nil, event: event("SessionStart"), now: t0))
        #expect(rec.sessionId == "s1")
        #expect(rec.state == .idle)
        #expect(rec.cwd == "/tmp/p")
        #expect(rec.startedAt == t0)
        #expect(rec.busySince == nil)
    }

    @Test func promptStartsThinkingAndBusyClock() throws {
        let idle = SessionReducer.reduce(nil, event: event("SessionStart"), now: t0)
        let rec = try #require(SessionReducer.reduce(idle, event: event("UserPromptSubmit"), now: t1))
        #expect(rec.state == .thinking)
        #expect(rec.busySince == t1)
        #expect(rec.startedAt == t0)
    }

    @Test func toolUsePreservesBusySinceAndSetsLabel() throws {
        var rec = SessionReducer.reduce(nil, event: event("UserPromptSubmit"), now: t0)
        rec = SessionReducer.reduce(rec, event: event("PreToolUse", tool: "Bash"), now: t1)
        let tool = try #require(rec)
        #expect(tool.state == .tool)
        #expect(tool.label == "Running")
        #expect(tool.busySince == t0)

        let back = try #require(SessionReducer.reduce(tool, event: event("PostToolUse", tool: "Bash"), now: t2))
        #expect(back.state == .thinking)
        #expect(back.label == nil)
        #expect(back.busySince == t0)
    }

    @Test func notificationMeansWaiting() throws {
        let thinking = SessionReducer.reduce(nil, event: event("UserPromptSubmit"), now: t0)
        let rec = try #require(SessionReducer.reduce(thinking, event: event("Notification"), now: t1))
        #expect(rec.state == .waiting)
        #expect(rec.busySince == t0)
    }

    @Test func stopResetsToIdle() throws {
        let thinking = SessionReducer.reduce(nil, event: event("UserPromptSubmit"), now: t0)
        let rec = try #require(SessionReducer.reduce(thinking, event: event("Stop"), now: t1))
        #expect(rec.state == .idle)
        #expect(rec.label == nil)
        #expect(rec.busySince == nil)
        #expect(rec.updatedAt == t1)
    }

    @Test func unknownEventChangesNothing() throws {
        let thinking = SessionReducer.reduce(nil, event: event("UserPromptSubmit"), now: t0)
        let rec = SessionReducer.reduce(thinking, event: event("SomethingNew"), now: t1)
        #expect(rec == thinking)
    }

    @Test func transcriptPathCapturedAndKeptAcrossEvents() throws {
        let start = try #require(HookEvent.parse(eventName: "SessionStart", payload: Data(
            #"{"session_id":"s1","cwd":"/tmp/p","transcript_path":"/tmp/t.jsonl"}"#.utf8)))
        var rec = SessionReducer.reduce(nil, event: start, now: t0)
        #expect(rec?.transcriptPath == "/tmp/t.jsonl")
        // later events without the field must not erase it
        rec = SessionReducer.reduce(rec, event: event("Stop"), now: t1)
        #expect(rec?.transcriptPath == "/tmp/t.jsonl")
    }

    @Test func recordsWithoutTranscriptPathStillDecode() throws {
        // records written by older builds lack the key
        let old = Data(#"{"cwd":"/tmp/p","sessionId":"s1","startedAt":"2026-01-01T00:00:00Z","state":"idle","updatedAt":"2026-01-01T00:00:00Z"}"#.utf8)
        let rec = try SessionRecord.decode(old)
        #expect(rec.transcriptPath == nil)
    }

    @Test func recordRoundTripsDeterministically() throws {
        let rec = try #require(SessionReducer.reduce(nil, event: event("UserPromptSubmit"), now: t0))
        let data = try rec.encoded()
        #expect(try SessionRecord.decode(data) == rec)
        #expect(try rec.encoded() == data)  // sorted keys → stable bytes
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""sessionId":"s1""#))
        #expect(json.contains(#""state":"thinking""#))
    }
}
