import AppKit
import StatusBarCore

/// Bakes the entire menu bar label — activity text, Clawd icon, usage text —
/// into ONE NSImage. A MenuBarExtra label is flattened into the status
/// button's single image slot plus title: only the first Image survives and
/// it always precedes any text, so a multi-view HStack can neither express
/// the textFirst order nor keep the icon once the activity text is itself an
/// image (the shimmer). Compositing sidesteps the slots entirely.
enum LabelComposite {
    static let spacing: CGFloat = 4
    static let height: CGFloat = 24

    static func image(model: MenuBarLabelModel, icon: ClawdIcon,
                      shimmerPhase: Double, dark: Bool) -> NSImage {
        let activity: (image: NSImage, offsetY: CGFloat)? = model.activityText.map { text in
            let baked = (model.state == .thinking || model.state == .tool)
                ? ShimmerText.image(text, phase: shimmerPhase, dark: dark)
                : ShimmerText.plain(text, dark: dark)
            return (image: baked, offsetY: 0)
        }
        let iconPart = cachedImage(for: icon, dark: dark)
        let usage = model.usageText.map { text in
            (image: ShimmerText.plain(text, dark: dark, monospacedDigits: true),
             offsetY: CGFloat(0))
        }

        // textFirst: [activity][icon][usage] — the status item is
        // right-anchored, so icon + % stay put while the text grows leftward.
        let parts = (model.textLeading ? [activity, iconPart, usage]
                                       : [iconPart, activity, usage])
            .compactMap { $0 }
            .filter { $0.image.size.width > 0 }
        guard !parts.isEmpty else { return NSImage(size: NSSize(width: 1, height: height)) }

        let totalWidth = parts.map(\.image.size.width).reduce(0, +)
            + spacing * CGFloat(parts.count - 1)
        let size = NSSize(width: totalWidth, height: height)
        return NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                // Canvas is y-up; offsetY was measured in y-down (visual)
                // terms, so subtract it to nudge the artwork toward center.
                let y = (height - part.image.size.height) / 2 - part.offsetY
                part.image.draw(in: NSRect(x: x, y: y,
                                           width: part.image.size.width,
                                           height: part.image.size.height))
                x += part.image.size.width + spacing
            }
            return true
        }
    }

    /// Decoded PNGs cached per icon case — the busy tick would otherwise
    /// re-read and re-decode the same file from disk 8 times a second.
    private static var imageCache: [ClawdIcon: (image: NSImage, offsetY: CGFloat)] = [:]

    private static func cachedImage(for icon: ClawdIcon,
                                    dark: Bool) -> (image: NSImage, offsetY: CGFloat)? {
        if let cached = imageCache[icon] { return cached }
        guard let bundle = ResourceBundle.resolved,
              let url = bundle.url(forResource: "clawd/\(icon.rawValue)", withExtension: "png"),
              let nsImage = NSImage(contentsOf: url)
        else { return sfFallback(for: icon, dark: dark) }
        nsImage.size = NSSize(width: 24, height: 24)
        let entry = (image: nsImage, offsetY: verticalCenteringOffset(nsImage))
        imageCache[icon] = entry
        return entry
    }

    /// SF Symbols load as template images that draw black; tint to match the
    /// baked text color. Not cached: dark mode can flip between calls.
    private static func sfFallback(for icon: ClawdIcon,
                                   dark: Bool) -> (image: NSImage, offsetY: CGFloat)? {
        guard let symbol = NSImage(systemSymbolName: icon.sfFallback,
                                   accessibilityDescription: nil)
        else { return nil }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            (dark ? NSColor.white : .black).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return (image: tinted, offsetY: 0)
    }

    /// Points between the canvas center and the opaque artwork's vertical
    /// center; negative shifts the image up (visual/y-down terms). Measured
    /// from the alpha channel once per icon at cache time.
    private static func verticalCenteringOffset(_ nsImage: NSImage) -> CGFloat {
        guard let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return 0 }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                .map { $0.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)) } != nil
        }
        guard drawn else { return 0 }

        // Bitmap-context memory row 0 is the visual TOP scanline.
        var minRow = h, maxRow = -1
        for row in 0..<h {
            let base = row * w * 4
            if (0..<w).contains(where: { pixels[base + $0 * 4 + 3] > 10 }) {
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
            }
        }
        guard maxRow >= minRow else { return 0 }
        let contentCenter = CGFloat(minRow + maxRow + 1) / 2
        return (CGFloat(h) / 2 - contentCenter) * nsImage.size.height / CGFloat(h)
    }
}
