import SwiftUI
import StatusBarCore

struct MenuBarLabelView: View {
    let model: MenuBarLabelModel
    let icon: ClawdIcon

    var body: some View {
        // MenuBarExtra labels render Text + Image only; colors are flattened
        // to template by the system, so levels are shown via dots in the popover,
        // not here.
        HStack(spacing: 4) {
            iconImage
            if let text = barText {
                Text(text)
            }
        }
    }

    private var barText: String? {
        let parts = [model.activityText, model.usageText].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private var iconImage: Image {
        if let nsImage = Self.cachedImage(for: icon) {
            return Image(nsImage: nsImage).renderingMode(.original)
        }
        return Image(systemName: icon.sfFallback)
    }

    /// Decoded PNGs cached per icon case — the 1 Hz elapsed tick would
    /// otherwise re-read and re-decode the same file from disk every second.
    private static var imageCache: [ClawdIcon: NSImage] = [:]

    private static func cachedImage(for icon: ClawdIcon) -> NSImage? {
        if let cached = imageCache[icon] { return cached }
        guard let bundle = ResourceBundle.resolved,
              let url = bundle.url(forResource: "clawd/\(icon.rawValue)", withExtension: "png"),
              let nsImage = NSImage(contentsOf: url)
        else { return nil }
        nsImage.size = NSSize(width: 20, height: 20)
        imageCache[icon] = nsImage
        return nsImage
    }
}
