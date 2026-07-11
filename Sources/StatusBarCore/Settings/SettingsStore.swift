import Foundation
import Observation

/// All user preferences. Each property persists on set; adding a future
/// setting = add one property + one line in init (spec: extensible settings).
@Observable @MainActor
public final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    public var showUsageOnBar: Bool {
        didSet { defaults.set(showUsageOnBar, forKey: "showUsageOnBar") }
    }
    public var displayStyleRaw: String {
        didSet { defaults.set(displayStyleRaw, forKey: "displayStyleRaw") }
    }
    public var pollMinutes: Int {
        didSet { defaults.set(pollMinutes, forKey: "pollMinutes") }
    }
    public var yellowAt: Double {
        didSet { defaults.set(yellowAt, forKey: "yellowAt") }
    }
    public var redAt: Double {
        didSet { defaults.set(redAt, forKey: "redAt") }
    }
    public var hiddenAccounts: [String] {
        didSet { defaults.set(hiddenAccounts, forKey: "hiddenAccounts") }
    }
    public var messageStyleId: String {
        didSet { defaults.set(messageStyleId, forKey: "messageStyleId") }
    }

    public var displayStyle: DisplayStyle {
        get { DisplayStyle(rawValue: displayStyleRaw) ?? .full }
        set { displayStyleRaw = newValue.rawValue }
    }

    /// Total: an unknown persisted id falls back to Classic (never crashes,
    /// never writes the fallback back to defaults).
    public var messageStyle: MessageStyle {
        MessageStyles.style(id: messageStyleId)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showUsageOnBar = defaults.object(forKey: "showUsageOnBar") as? Bool ?? true
        displayStyleRaw = defaults.string(forKey: "displayStyleRaw") ?? DisplayStyle.full.rawValue
        pollMinutes = defaults.object(forKey: "pollMinutes") as? Int ?? 5
        yellowAt = defaults.object(forKey: "yellowAt") as? Double ?? 50
        redAt = defaults.object(forKey: "redAt") as? Double ?? 80
        hiddenAccounts = defaults.stringArray(forKey: "hiddenAccounts") ?? []
        messageStyleId = defaults.string(forKey: "messageStyleId") ?? "classic"
    }
}
