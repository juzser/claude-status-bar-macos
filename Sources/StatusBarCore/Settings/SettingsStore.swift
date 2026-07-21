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
    public var showElapsedOnBar: Bool {
        didSet { defaults.set(showElapsedOnBar, forKey: "showElapsedOnBar") }
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
    public var languageRaw: String {
        didSet { defaults.set(languageRaw, forKey: "languageRaw") }
    }
    /// Hex ("#RRGGBB") for the "normal" (below-yellow) usage level. Default is
    /// NSColor.systemGreen's sRGB hex, so a fresh install renders identically
    /// to the old hardcoded color.
    public var normalColorHex: String {
        didSet { defaults.set(normalColorHex, forKey: "normalColorHex") }
    }
    /// Hex ("#RRGGBB") for the yellow (mid) usage level. Default is
    /// NSColor.systemYellow's sRGB hex, so a fresh install renders
    /// identically to the old hardcoded color.
    public var yellowColorHex: String {
        didSet { defaults.set(yellowColorHex, forKey: "yellowColorHex") }
    }
    /// Hex ("#RRGGBB") for the red (high) usage level. Default is
    /// NSColor.systemRed's sRGB hex, so a fresh install renders
    /// identically to the old hardcoded color.
    public var redColorHex: String {
        didSet { defaults.set(redColorHex, forKey: "redColorHex") }
    }
    public var textAnimationEnabled: Bool {
        didSet { defaults.set(textAnimationEnabled, forKey: "textAnimationEnabled") }
    }
    /// When true and the `token-slayer` CLI resolves, accounts/usage/session
    /// switching delegate to it instead of the native Keychain-based
    /// mechanism. Defaults to true so an install is picked up automatically;
    /// false lets a user opt back into native behavior even with the CLI
    /// present.
    public var useTokenSlayer: Bool {
        didSet { defaults.set(useTokenSlayer, forKey: "useTokenSlayer") }
    }

    public var displayStyle: DisplayStyle {
        get { DisplayStyle(rawValue: displayStyleRaw) ?? .full }
        set { displayStyleRaw = newValue.rawValue }
    }

    /// Total: an unrecognized persisted value falls back to English (never
    /// crashes, never writes the fallback back to defaults).
    public var language: Language {
        get { Language(rawValue: languageRaw) ?? .english }
        set { languageRaw = newValue.rawValue }
    }

    /// Total: an unknown persisted id falls back to Classic (never crashes,
    /// never writes the fallback back to defaults).
    public var messageStyle: MessageStyle {
        MessageStyles.style(id: messageStyleId, language: language)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showUsageOnBar = defaults.object(forKey: "showUsageOnBar") as? Bool ?? true
        showElapsedOnBar = defaults.object(forKey: "showElapsedOnBar") as? Bool ?? true
        displayStyleRaw = defaults.string(forKey: "displayStyleRaw") ?? DisplayStyle.full.rawValue
        pollMinutes = defaults.object(forKey: "pollMinutes") as? Int ?? 5
        yellowAt = defaults.object(forKey: "yellowAt") as? Double ?? 50
        redAt = defaults.object(forKey: "redAt") as? Double ?? 80
        hiddenAccounts = defaults.stringArray(forKey: "hiddenAccounts") ?? []
        messageStyleId = defaults.string(forKey: "messageStyleId") ?? "classic"
        languageRaw = defaults.string(forKey: "languageRaw") ?? Language.english.rawValue
        normalColorHex = defaults.string(forKey: "normalColorHex") ?? "#34C759"
        yellowColorHex = defaults.string(forKey: "yellowColorHex") ?? "#FFCC00"
        redColorHex = defaults.string(forKey: "redColorHex") ?? "#FF3B30"
        textAnimationEnabled = defaults.object(forKey: "textAnimationEnabled") as? Bool ?? true
        useTokenSlayer = defaults.object(forKey: "useTokenSlayer") as? Bool ?? true
    }
}
