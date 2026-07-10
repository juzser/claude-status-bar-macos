import Foundation

/// Clawd artwork variants. rawValue == artwork file basename in Resources/clawd.
public enum ClawdIcon: String, CaseIterable, Equatable, Sendable {
    case idle, thinking, notification, typing, building, debugger, carrying

    /// SF Symbol used when the artwork file is missing from the bundle.
    public var sfFallback: String {
        switch self {
        case .idle: return "moon.zzz"
        case .thinking: return "brain"
        case .notification: return "bell.badge"
        case .typing: return "keyboard"
        case .building: return "hammer"
        case .debugger: return "magnifyingglass"
        case .carrying: return "book"
        }
    }
}

public enum StatusIcon {
    public static func icon(for record: SessionRecord?) -> ClawdIcon {
        guard let record else { return .idle }
        switch record.state {
        case .idle: return .idle
        case .thinking: return .thinking
        case .waiting: return .notification
        case .tool:
            switch record.label {
            case "Editing": return .typing
            case "Running": return .building
            case "Searching": return .debugger
            case "Reading": return .carrying
            default: return .typing
            }
        }
    }
}
