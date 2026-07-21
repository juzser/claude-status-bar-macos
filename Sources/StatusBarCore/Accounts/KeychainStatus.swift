import Security

/// Coarse classification of a raw Keychain `OSStatus`, kept small
/// deliberately: existing diagnostic logs (`native-switch.log`,
/// `token-resolution.log`) can't attribute a self-heal repair-read failure
/// to a specific cause today — every failure looks the same ("no live
/// credentials found"), whether the item is genuinely missing or the read
/// was blocked because the process isn't trusted yet. Distinguishing at
/// least these cases turns "prompts still happen sometimes" bug reports
/// into something checkable against real log evidence instead of a guess.
public enum KeychainStatus: Equatable, Sendable {
    case success
    case itemNotFound
    case interactionNotAllowed
    case other(OSStatus)

    public init(_ status: OSStatus) {
        switch status {
        case errSecSuccess: self = .success
        case errSecItemNotFound: self = .itemNotFound
        case errSecInteractionNotAllowed: self = .interactionNotAllowed
        default: self = .other(status)
        }
    }

    /// Short, log-friendly text — never includes any credential data, only
    /// the status classification.
    public var description: String {
        switch self {
        case .success: return "success"
        case .itemNotFound: return "itemNotFound"
        case .interactionNotAllowed: return "interactionNotAllowed"
        case let .other(status): return "other(\(status))"
        }
    }
}
