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

    /// 0..<1 position of the sweep at `date`; feed `AppState.tick` so every
    /// 8 fps tick advances the band.
    static func phase(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return t.truncatingRemainder(dividingBy: period) / period
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
        // 13 pt system font matches SwiftUI's default Text in the menu bar.
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let full: NSColor = dark ? .white : .black
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: full.withAlphaComponent(0.55),
        ])
        var size = attributed.size()
        size.width = ceil(size.width)
        size.height = ceil(size.height)
        guard size.width > 0, size.height > 0 else { return NSImage(size: size) }

        let band = max(24, size.width * 0.5)
        // phase 0 puts the band fully off the left edge, 1 fully off the right.
        let bandX = CGFloat(phase) * (size.width + band) - band
        return NSImage(size: size, flipped: false) { _ in
            attributed.draw(at: .zero)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.setBlendMode(.sourceAtop)
            NSGradient(colors: [full.withAlphaComponent(0), full, full.withAlphaComponent(0)])?
                .draw(in: NSRect(x: bandX, y: 0, width: band, height: size.height), angle: 0)
            return true
        }
    }
}
