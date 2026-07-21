import SwiftUI
import StatusBarCore

struct AccountsSection: View {
    let accounts: [Account]
    let states: [String: AccountUsageState]
    let yellowAt: Double
    let redAt: Double
    let normalColor: Color
    let yellowColor: Color
    let redColor: Color
    let now: Date
    let switchFailedAccountId: String?
    /// Stderr text from a failed slayer-mode switch; nil for a native-mode
    /// failure, which falls back to `AccountRow`'s generic message.
    let switchFailedMessage: String?
    let onSwitch: (Account) -> Void
    let onRelogin: (Account) -> Void
    let onAddAccount: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accounts").font(.caption).foregroundStyle(.secondary)
            if accounts.isEmpty {
                Text("No Claude account found — log in with claude /login")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { account in
                    AccountRow(account: account, state: states[account.id],
                               yellowAt: yellowAt, redAt: redAt, normalColor: normalColor,
                               yellowColor: yellowColor, redColor: redColor, now: now,
                               showActiveBadge: accounts.count > 1,
                               switchFailed: switchFailedAccountId == account.id,
                               switchFailedMessage: switchFailedAccountId == account.id ? switchFailedMessage : nil,
                               onSwitch: onSwitch, onRelogin: onRelogin)
                }
            }
            Button("Add Account") { onAddAccount() }
                .controlSize(.small)
        }
    }
}

private struct AccountRow: View {
    let account: Account
    let state: AccountUsageState?
    let yellowAt: Double
    let redAt: Double
    let normalColor: Color
    let yellowColor: Color
    let redColor: Color
    let now: Date
    let showActiveBadge: Bool
    let switchFailed: Bool
    let switchFailedMessage: String?
    let onSwitch: (Account) -> Void
    let onRelogin: (Account) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(account.alias ?? account.email ?? account.id)
                    .fontWeight(account.isActive ? .bold : .regular)
                if account.alias != nil, let email = account.email {
                    Text(email).font(.caption).foregroundStyle(.secondary)
                }
                if account.isActive && showActiveBadge {
                    Text("active").font(.caption2).padding(.horizontal, 4)
                        .background(.tint.opacity(0.2), in: Capsule())
                }
                if !account.isActive && account.slot != nil && showActiveBadge {
                    Button("Switch") { onSwitch(account) }
                        .controlSize(.small)
                }
                Spacer()
                if state?.needsRelogin == true {
                    Label("re-login needed", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                    Button("Log in") { onRelogin(account) }
                        .controlSize(.small)
                } else if state?.freshness == .fresh {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                        .help("Logged in")
                }
            }
            if switchFailed {
                Text(switchFailedMessage ?? "Switch failed — check native-switch.log")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let snapshot = state?.snapshot {
                UsageBar(title: "5h", window: snapshot.fiveHour,
                         yellowAt: yellowAt, redAt: redAt, normalColor: normalColor,
                         yellowColor: yellowColor, redColor: redColor, now: now)
                UsageBar(title: "7d", window: snapshot.sevenDay,
                         yellowAt: yellowAt, redAt: redAt, normalColor: normalColor,
                         yellowColor: yellowColor, redColor: redColor, now: now)
            } else {
                Text("No usage data").font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(state?.freshness == .fresh ? 1.0 : 0.5)
    }
}

private struct UsageBar: View {
    let title: String
    let window: UsageWindow?
    let yellowAt: Double
    let redAt: Double
    let normalColor: Color
    let yellowColor: Color
    let redColor: Color
    let now: Date

    var body: some View {
        if let window {
            HStack(spacing: 6) {
                Text(title).font(.caption2.monospaced()).frame(width: 18, alignment: .leading)
                ProgressView(value: min(window.utilization, 100), total: 100)
                    .tint(color)
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
                if let resetsAt = window.resetsAt, resetsAt > now {
                    Text("resets in \(MenuBarText.elapsed(resetsAt.timeIntervalSince(now)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var color: Color {
        switch UsageLevel.level(for: window?.utilization ?? 0, yellowAt: yellowAt, redAt: redAt) {
        case .green: return normalColor
        case .yellow: return yellowColor
        case .red: return redColor
        }
    }
}
