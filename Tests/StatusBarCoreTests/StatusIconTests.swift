import Foundation
import Testing
@testable import StatusBarCore

private func record(_ state: SessionState, label: String? = nil) -> SessionRecord {
    let now = Date(timeIntervalSince1970: 0)
    return SessionRecord(sessionId: "s", state: state, label: label, cwd: "/tmp",
                         startedAt: now, busySince: nil, updatedAt: now)
}

@Suite struct StatusIconTests {
    @Test func statesMapToIcons() {
        #expect(StatusIcon.icon(for: nil) == .idle)
        #expect(StatusIcon.icon(for: record(.idle)) == .idle)
        #expect(StatusIcon.icon(for: record(.thinking)) == .thinking)
        #expect(StatusIcon.icon(for: record(.waiting)) == .notification)
    }

    @Test func toolLabelsMapToIcons() {
        #expect(StatusIcon.icon(for: record(.tool, label: "Editing")) == .typing)
        #expect(StatusIcon.icon(for: record(.tool, label: "Running")) == .building)
        #expect(StatusIcon.icon(for: record(.tool, label: "Searching")) == .debugger)
        #expect(StatusIcon.icon(for: record(.tool, label: "Reading")) == .carrying)
        #expect(StatusIcon.icon(for: record(.tool, label: "Browsing")) == .typing)
        #expect(StatusIcon.icon(for: record(.tool, label: nil)) == .typing)
    }

    @Test func rawValuesMatchArtworkBasenames() {
        #expect(Set(ClawdIcon.allCases.map(\.rawValue)) ==
                ["idle", "thinking", "notification", "typing", "building",
                 "debugger", "carrying"])
    }
}
