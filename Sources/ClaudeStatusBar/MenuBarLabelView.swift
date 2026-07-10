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
        if let url = Bundle.module.url(forResource: "clawd/\(icon.rawValue)",
                                       withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            nsImage.size = NSSize(width: 18, height: 18)
            return Image(nsImage: nsImage).renderingMode(.original)
        }
        return Image(systemName: icon.sfFallback)
    }
}
