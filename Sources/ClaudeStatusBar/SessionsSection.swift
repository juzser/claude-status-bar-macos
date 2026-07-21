import SwiftUI
import StatusBarCore

struct SessionsSection: View {
    let sessions: [SessionRecord]
    /// sessionId -> Claude Code session title; falls back to the folder name.
    let titles: [String: String]
    /// sessionId -> token-slayer `billed_account`, a small secondary
    /// annotation joined in slayer mode only — empty in native mode, and
    /// there's no row for slayer-only (`ide:*`) entries since this only ever
    /// annotates rows the hook already produced.
    var billedAccounts: [String: String] = [:]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions").font(.caption).foregroundStyle(.secondary)
            if sessions.isEmpty {
                Text("No active Claude Code sessions")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(sessions, id: \.sessionId) { session in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(titles[session.sessionId] ?? projectName(session.cwd))
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(stateText(session)).foregroundStyle(.secondary)
                                .layoutPriority(1)
                        }
                        .font(.callout)
                        if let billedAccount = billedAccounts[session.sessionId] {
                            Text(billedAccount)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func projectName(_ cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    private func stateText(_ session: SessionRecord) -> String {
        let elapsed = session.busySince.map {
            " · " + MenuBarText.elapsed(now.timeIntervalSince($0))
        } ?? ""
        switch session.state {
        case .idle: return "Idle"
        case .thinking: return "Thinking\(elapsed)"
        case .waiting: return "Waiting for you"
        case .tool: return "\(session.label ?? "Working")\(elapsed)"
        }
    }
}
