import AppKit

/// Renders the bar's activity text with a left→right shimmer. MenuBarExtra
/// flattens SwiftUI Text foreground colors to a monochrome template, so the
/// effect has to be baked into a bitmap: draw the string dimmed, then sweep a
/// full-strength band across it — sourceAtop keeps the band inside the glyphs.
///
/// Everything here runs on the menu bar label's animation frame, so the whole
/// file is written around not re-doing work per frame: the immutable drawing
/// attributes are `static let`s, text measurement is memoized, and static text
/// is baked once into an image and handed back on later frames.
enum ShimmerText {
    /// One full sweep (off-screen left → off-screen right).
    static let period: TimeInterval = 1.6

    /// Menu bar space is shared with every other status item; text longer
    /// than this is tail-truncated at draw time.
    static let maxTextWidth: CGFloat = 220

    /// Every cache below is bounded and cleared wholesale on overflow rather
    /// than evicted entry by entry. The activity string carries a live elapsed
    /// counter, so it mints a fresh key every second and an unbounded
    /// dictionary would grow for the life of the process; wholesale clearing
    /// costs one cold frame and keeps the bookkeeping free.
    private static let cacheLimit = 64

    // MARK: - Immutable drawing attributes

    /// Tail truncation only applies when the string is drawn into a rect
    /// narrower than its natural size.
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// 13 pt system font matches SwiftUI's default Text in the menu bar.
    private static let regularFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private static let monoDigitFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize, weight: .regular)

    private static func attributedString(_ text: String, color: NSColor,
                                         monospacedDigits: Bool = false) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: monospacedDigits ? monoDigitFont : regularFont,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    // MARK: - Measurement

    private struct MetricsKey: Hashable {
        let text: String
        let monospacedDigits: Bool
    }

    /// Color is deliberately absent from the key: it doesn't affect text
    /// metrics, so keying on it would only fragment the cache.
    private static var metricsCache: [MetricsKey: NSSize] = [:]

    /// `NSAttributedString.size()` runs a full TextKit layout pass, and the
    /// label measures twice per frame (activity text plus usage text).
    private static func measure(_ attributed: NSAttributedString,
                                key: MetricsKey) -> NSSize {
        if let hit = metricsCache[key] { return hit }
        var size = attributed.size()
        size.width = min(ceil(size.width), maxTextWidth)
        size.height = ceil(size.height)
        if metricsCache.count >= cacheLimit { metricsCache.removeAll(keepingCapacity: true) }
        metricsCache[key] = size
        return size
    }

    /// 0..<1 position of the sweep at `date`; feed `TickClock.now` so every
    /// animation tick advances the band.
    static func phase(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return t.truncatingRemainder(dividingBy: period) / period
    }

    // MARK: - Static text

    private struct PlainKey: Hashable {
        let text: String
        let dark: Bool
        let monospacedDigits: Bool
        /// Retained by the cache, so this can't dangle; NSColor's `isEqual:`
        /// compares color space and components, which is exactly the identity
        /// that matters for what gets drawn.
        let color: NSColor?
    }

    private static var plainCache: [PlainKey: NSImage] = [:]

    /// Static text baked into an image. It cannot stay a SwiftUI Text: a
    /// MenuBarExtra label holding a single Image plus Texts is flattened to
    /// the status button's image+title slots, and the image always leads —
    /// silently ignoring the HStack's textFirst order.
    ///
    /// Memoized on everything it draws from. This is the label's highest-value
    /// cache: the usage percentage changes every few minutes at most, yet it
    /// was re-laid-out and re-rasterized on every animation frame.
    static func plain(_ text: String, dark: Bool,
                      monospacedDigits: Bool = false, color: NSColor? = nil) -> NSImage {
        let key = PlainKey(text: text, dark: dark,
                           monospacedDigits: monospacedDigits, color: color)
        if let hit = plainCache[key] { return hit }
        let baked = renderPlain(text, dark: dark, monospacedDigits: monospacedDigits, color: color)
        if plainCache.count >= cacheLimit { plainCache.removeAll(keepingCapacity: true) }
        plainCache[key] = baked
        return baked
    }

    private static func renderPlain(_ text: String, dark: Bool,
                                    monospacedDigits: Bool, color: NSColor?) -> NSImage {
        let attributed = attributedString(text, color: color ?? (dark ? .white : .black),
                                          monospacedDigits: monospacedDigits)
        let size = measure(attributed, key: MetricsKey(text: text,
                                                       monospacedDigits: monospacedDigits))
        guard size.width > 0, size.height > 0 else { return NSImage(size: size) }
        return NSImage(size: size, flipped: false) { rect in
            // draw(in:) — not draw(at:) — so byTruncatingTail can add the
            // ellipsis when the string is wider than maxTextWidth.
            attributed.draw(in: rect)
            return true
        }
    }

    // MARK: - Shimmering text

    /// The dim base must be an opaque gray, not full.withAlphaComponent:
    /// sourceAtop of a color onto an alpha-faded copy of itself is a no-op
    /// (result = Da·(Sc·Sa + Dc·(1−Sa)) = Da when Sc == Dc), so the band would
    /// change nothing. Blending toward the background color keeps alpha at 1
    /// and lets the band ramp the glyph color dim→full.
    private static let dimOnDark = NSColor.white.blended(withFraction: 0.45, of: .black) ?? .white
    private static let dimOnLight = NSColor.black.blended(withFraction: 0.45, of: .white) ?? .black

    /// The sweeping band. Only its destination rect moves between frames, so
    /// the gradient itself is built once per appearance instead of per frame.
    private static let bandOnDark = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0), .white, NSColor.white.withAlphaComponent(0)])
    private static let bandOnLight = NSGradient(colors: [
        NSColor.black.withAlphaComponent(0), .black, NSColor.black.withAlphaComponent(0)])

    private struct DimmedKey: Hashable {
        let text: String
        let dark: Bool
    }

    /// Unlike `plain`, the dimmed base string is cacheable on its own but the
    /// finished image is not — the band's position changes every frame — so
    /// only the string is kept.
    private static var dimmedCache: [DimmedKey: NSAttributedString] = [:]

    private static func dimmed(_ text: String, dark: Bool) -> NSAttributedString {
        let key = DimmedKey(text: text, dark: dark)
        if let hit = dimmedCache[key] { return hit }
        let made = attributedString(text, color: dark ? dimOnDark : dimOnLight)
        if dimmedCache.count >= cacheLimit { dimmedCache.removeAll(keepingCapacity: true) }
        dimmedCache[key] = made
        return made
    }

    static func image(_ text: String, phase: Double, dark: Bool) -> NSImage {
        let attributed = dimmed(text, dark: dark)
        let size = measure(attributed, key: MetricsKey(text: text, monospacedDigits: false))
        guard size.width > 0, size.height > 0 else { return NSImage(size: size) }

        let band = max(24, size.width * 0.5)
        // phase 0 puts the band fully off the left edge, 1 fully off the right.
        let bandX = CGFloat(phase) * (size.width + band) - band
        let gradient = dark ? bandOnDark : bandOnLight
        return NSImage(size: size, flipped: false) { rect in
            attributed.draw(in: rect)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.setBlendMode(.sourceAtop)
            gradient?.draw(in: NSRect(x: bandX, y: 0, width: band, height: size.height), angle: 0)
            return true
        }
    }
}
