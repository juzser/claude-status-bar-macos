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

    /// Memoized `init?(hex:)` for the render path. The menu bar label re-reads
    /// the three user colors on every animation frame, but they only change
    /// when the user edits them in Settings — parsing them fresh minted three
    /// NSColors per frame for nothing.
    @MainActor static func cached(hex: String) -> NSColor? {
        ColorCache.lookup(hex, in: &ColorCache.ns) { NSColor(hex: $0) }
    }
}

extension Color {
    init?(hex: String) {
        guard let c = HexColor.components(hex: hex) else { return nil }
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    /// See `NSColor.cached(hex:)`; the popover re-reads its colors on every
    /// row render for the same reason.
    @MainActor static func cached(hex: String) -> Color? {
        ColorCache.lookup(hex, in: &ColorCache.swiftUI) { Color(hex: $0) }
    }

    /// Round-trips a ColorPicker selection back to the hex string
    /// SettingsStore persists.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return HexColor.hex(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
    }
}

/// Backing store for the `cached(hex:)` helpers above.
///
/// Bounded and cleared wholesale on overflow rather than evicted one entry at
/// a time: in practice this only ever holds the three settings colors, but
/// dragging a ColorPicker writes a new hex on every mouse-move, and an
/// unbounded dictionary would grow for the life of the process.
@MainActor
private enum ColorCache {
    static var ns: [String: NSColor?] = [:]
    static var swiftUI: [String: Color?] = [:]
    private static let limit = 32

    /// Caches misses too — an unparseable hex is just as worth not re-parsing
    /// as a valid one, and `nil` is a legitimate value here rather than a
    /// cache miss.
    static func lookup<T>(_ hex: String,
                          in cache: inout [String: T?],
                          make: (String) -> T?) -> T? {
        if let hit = cache[hex] { return hit }
        if cache.count >= limit { cache.removeAll(keepingCapacity: true) }
        let made = make(hex)
        cache[hex] = made
        return made
    }
}
