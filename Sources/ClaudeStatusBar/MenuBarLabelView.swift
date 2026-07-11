import SwiftUI
import StatusBarCore

struct MenuBarLabelView: View {
    let model: MenuBarLabelModel
    let icon: ClawdIcon
    var shimmerPhase: Double = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // MenuBarExtra labels render Text + Image only; colors are flattened
        // to template by the system, so levels are shown via dots in the popover,
        // not here — and the shimmer must be baked into an NSImage.
        HStack(spacing: 4) {
            if model.textLeading {
                // [activity][icon][usage]: the status item is right-anchored,
                // so icon + % stay put while the text grows leftward.
                activityView
                iconImage
                if let usage = model.usageText {
                    Text(usage).monospacedDigit()
                }
            } else {
                iconImage
                activityView
                if let usage = model.usageText {
                    Text(usage).monospacedDigit()
                }
            }
        }
    }

    /// Busy states shimmer; waiting stays plain text (no motion while the
    /// session sits on the user).
    @ViewBuilder private var activityView: some View {
        if let activity = model.activityText {
            if model.state == .thinking || model.state == .tool {
                Image(nsImage: ShimmerText.image(activity, phase: shimmerPhase,
                                                 dark: colorScheme == .dark))
                    .renderingMode(.original)
            } else {
                Text(activity)
            }
        }
    }

    @ViewBuilder private var iconImage: some View {
        if let cached = Self.cachedImage(for: icon) {
            // The Clawd PNGs carry uneven transparent padding, so the artwork
            // sits below the canvas center; nudge each frame by its measured
            // offset (offset(y:) is visual-only, layout is unaffected).
            Image(nsImage: cached.image).renderingMode(.original)
                .offset(y: cached.offsetY)
        } else {
            Image(systemName: icon.sfFallback)
        }
    }

    /// Decoded PNGs cached per icon case — the 1 Hz elapsed tick would
    /// otherwise re-read and re-decode the same file from disk every second.
    private static var imageCache: [ClawdIcon: (image: NSImage, offsetY: CGFloat)] = [:]

    private static func cachedImage(for icon: ClawdIcon) -> (image: NSImage, offsetY: CGFloat)? {
        if let cached = imageCache[icon] { return cached }
        guard let bundle = ResourceBundle.resolved,
              let url = bundle.url(forResource: "clawd/\(icon.rawValue)", withExtension: "png"),
              let nsImage = NSImage(contentsOf: url)
        else { return nil }
        nsImage.size = NSSize(width: 24, height: 24)
        let entry = (image: nsImage, offsetY: verticalCenteringOffset(nsImage))
        imageCache[icon] = entry
        return entry
    }

    /// Points between the canvas center and the opaque artwork's vertical
    /// center; negative shifts the image up. Measured from the alpha channel
    /// once per icon at cache time.
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

        // Bitmap-context memory row 0 is the visual TOP scanline, matching
        // SwiftUI's y-down offset direction.
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
