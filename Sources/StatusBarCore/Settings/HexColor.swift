import Foundation

/// Minimal sRGB hex ("#RRGGBB") <-> component conversion for persisted
/// colors. UserDefaults has no native NSColor/Color type, so SettingsStore
/// persists colors as hex strings; StatusBarCore stays framework-agnostic
/// (no AppKit/SwiftUI import anywhere in this target), so this only exposes
/// plain component doubles — NSColor/Color construction happens in the app
/// target that actually needs each type.
public enum HexColor {
    /// Parses "#RRGGBB" (leading "#" optional, case-insensitive) into sRGB
    /// components in 0...1. Malformed input (wrong length, non-hex digits)
    /// returns nil.
    public static func components(hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }

    /// Formats sRGB components (each clamped to 0...1) back to "#RRGGBB".
    public static func hex(r: Double, g: Double, b: Double) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
