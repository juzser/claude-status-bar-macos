import AppKit
import os

// DIAGNOSTIC(shimmer): temporary render-rate probe — remove once the
// "no visible animation" report is resolved.
private let shimmerLog = Logger(subsystem: "ClaudeStatusBar", category: "shimmer")
private nonisolated(unsafe) var renderCount = 0
private nonisolated(unsafe) var lastSampleAt = Date.distantPast

/// Renders the bar's activity text with a left→right shimmer. MenuBarExtra
/// flattens SwiftUI Text foreground colors to a monochrome template, so the
/// effect has to be baked into a bitmap: draw the string dimmed, then sweep a
/// full-strength band across it — sourceAtop keeps the band inside the glyphs.
enum ShimmerText {
    /// One full sweep (off-screen left → off-screen right).
    static let period: TimeInterval = 1.6

    /// Menu bar space is shared with every other status item; text longer
    /// than this is tail-truncated at draw time.
    static let maxTextWidth: CGFloat = 220

    /// 13 pt system font matches SwiftUI's default Text in the menu bar.
    /// Tail truncation only applies when the string is drawn into a rect
    /// narrower than its natural size.
    private static func attributedString(_ text: String, color: NSColor,
                                         monospacedDigits: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let size = NSFont.systemFontSize
        return NSAttributedString(string: text, attributes: [
            .font: monospacedDigits
                ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
                : NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ])
    }

    /// 0..<1 position of the sweep at `date`; feed `AppState.tick` so every
    /// 30 fps tick advances the band.
    static func phase(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return t.truncatingRemainder(dividingBy: period) / period
    }

    /// Static text baked into an image. It cannot stay a SwiftUI Text: a
    /// MenuBarExtra label holding a single Image plus Texts is flattened to
    /// the status button's image+title slots, and the image always leads —
    /// silently ignoring the HStack's textFirst order.
    static func plain(_ text: String, dark: Bool,
                      monospacedDigits: Bool = false, color: NSColor? = nil) -> NSImage {
        let attributed = attributedString(text, color: color ?? (dark ? .white : .black),
                                          monospacedDigits: monospacedDigits)
        var size = attributed.size()
        size.width = min(ceil(size.width), maxTextWidth)
        size.height = ceil(size.height)
        guard size.width > 0, size.height > 0 else { return NSImage(size: size) }
        return NSImage(size: size, flipped: false) { rect in
            // draw(in:) — not draw(at:) — so byTruncatingTail can add the
            // ellipsis when the string is wider than maxTextWidth.
            attributed.draw(in: rect)
            return true
        }
    }

    static func image(_ text: String, phase: Double, dark: Bool) -> NSImage {
        // DIAGNOSTIC(shimmer): sampled ~1/sec; renders-per-second ≈ fps.
        renderCount += 1
        let now = Date()
        if now.timeIntervalSince(lastSampleAt) >= 1 {
            shimmerLog.info("renders/s=\(renderCount) phase=\(phase, format: .fixed(precision: 3)) text=\(text, privacy: .public)")
            renderCount = 0
            lastSampleAt = now
        }
        let full: NSColor = dark ? .white : .black
        // The dim base must be an opaque gray, not full.withAlphaComponent:
        // sourceAtop of a color onto an alpha-faded copy of itself is a no-op
        // (result = Da·(Sc·Sa + Dc·(1−Sa)) = Da when Sc == Dc), so the band
        // would change nothing. Blending toward the background color keeps
        // alpha at 1 and lets the band ramp the glyph color dim→full.
        let dim = full.blended(withFraction: 0.45, of: dark ? .black : .white) ?? full
        let attributed = attributedString(text, color: dim)
        var size = attributed.size()
        size.width = min(ceil(size.width), maxTextWidth)
        size.height = ceil(size.height)
        guard size.width > 0, size.height > 0 else { return NSImage(size: size) }

        let band = max(24, size.width * 0.5)
        // phase 0 puts the band fully off the left edge, 1 fully off the right.
        let bandX = CGFloat(phase) * (size.width + band) - band
        return NSImage(size: size, flipped: false) { rect in
            attributed.draw(in: rect)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.setBlendMode(.sourceAtop)
            NSGradient(colors: [full.withAlphaComponent(0), full, full.withAlphaComponent(0)])?
                .draw(in: NSRect(x: bandX, y: 0, width: band, height: size.height), angle: 0)
            return true
        }
    }
}
