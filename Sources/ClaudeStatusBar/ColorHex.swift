import AppKit
import SwiftUI
import StatusBarCore

/// NSColor/Color bridges over StatusBarCore's framework-agnostic HexColor —
/// SettingsStore persists the user's normal-usage color as a "#RRGGBB"
/// string; the actual color types live here since StatusBarCore imports
/// neither AppKit nor SwiftUI.
extension NSColor {
    convenience init?(hex: String) {
        guard let c = HexColor.components(hex: hex) else { return nil }
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

extension Color {
    init?(hex: String) {
        guard let c = HexColor.components(hex: hex) else { return nil }
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    /// Round-trips a ColorPicker selection back to the hex string
    /// SettingsStore persists.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return HexColor.hex(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
    }
}
