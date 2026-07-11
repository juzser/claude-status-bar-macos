import Foundation

public enum DisplayStyle: String, CaseIterable, Sendable {
    case iconOnly, percent, full
}

public struct MenuBarLabelModel: Equatable, Sendable {
    public let state: SessionState
    public let activityText: String?
    public let usageText: String?
    public let fiveHourLevel: UsageLevel?
    public let sevenDayLevel: UsageLevel?
}

public enum MenuBarText {
    public static func model(display: SessionRecord?, usage: AccountUsageState?,
                             style: DisplayStyle, showUsage: Bool,
                             yellowAt: Double, redAt: Double,
                             verb: String, now: Date) -> MenuBarLabelModel {
        let state = display?.state ?? .idle

        var activity: String?
        if style != .iconOnly, let display {
            let time = display.busySince.map { elapsed(now.timeIntervalSince($0)) }
            switch display.state {
            case .tool:
                let label = display.label ?? "Working"
                activity = time.map { "\(label) · \($0)" } ?? label
            case .thinking:
                activity = time.map { "\(verb)… · \($0)" } ?? "\(verb)…"
            case .waiting:
                activity = "Waiting for you"
            case .idle:
                activity = nil
            }
        }

        var usageText: String?
        var fiveLevel: UsageLevel?
        var sevenLevel: UsageLevel?
        if showUsage, style != .iconOnly, let snapshot = usage?.snapshot {
            let five = snapshot.fiveHour.map { Int($0.utilization.rounded()) }
            let seven = snapshot.sevenDay.map { Int($0.utilization.rounded()) }
            fiveLevel = snapshot.fiveHour.map {
                UsageLevel.level(for: $0.utilization, yellowAt: yellowAt, redAt: redAt)
            }
            sevenLevel = snapshot.sevenDay.map {
                UsageLevel.level(for: $0.utilization, yellowAt: yellowAt, redAt: redAt)
            }
            switch style {
            case .percent:
                usageText = five.map { "\($0)%" }
            case .full:
                let parts = [five.map { "5h \($0)%" }, seven.map { "7d \($0)%" }]
                    .compactMap(\.self)
                usageText = parts.isEmpty ? nil : parts.joined(separator: " · ")
            case .iconOnly:
                usageText = nil
            }
        }

        return MenuBarLabelModel(state: state, activityText: activity,
                                 usageText: usageText,
                                 fiveHourLevel: fiveLevel, sevenDayLevel: sevenLevel)
    }

    public static func elapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        let minutes = (total % 3_600) / 60
        return "\(total / 3_600)h \(String(format: "%02d", minutes))m"
    }
}
