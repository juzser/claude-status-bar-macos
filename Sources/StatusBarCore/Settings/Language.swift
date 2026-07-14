import Foundation

/// Language affects only message-style menu bar phrases (thinking/tool/
/// waiting text) — Settings UI labels, style picker names, and the popover
/// stay English regardless of this setting.
public enum Language: String, CaseIterable, Sendable {
    case english, vietnamese
}
