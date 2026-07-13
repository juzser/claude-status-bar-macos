import AppKit
import SwiftUI
import StatusBarCore

struct MenuBarLabelView: View {
    let model: MenuBarLabelModel
    let icon: ClawdIcon
    var shimmerPhase: Double = 0
    let normalColor: NSColor
    let animateText: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The whole label is composited into one NSImage (LabelComposite):
        // MenuBarExtra flattens its label into the status button's single
        // image slot + title, so a multi-view HStack cannot control order
        // or keep more than one image.
        Image(nsImage: LabelComposite.image(model: model, icon: icon,
                                            shimmerPhase: shimmerPhase,
                                            dark: colorScheme == .dark,
                                            normalColor: normalColor,
                                            animateText: animateText))
            .renderingMode(.original)
    }
}
