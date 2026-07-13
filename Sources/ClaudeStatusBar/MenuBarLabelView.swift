import AppKit
import SwiftUI
import StatusBarCore

struct MenuBarLabelView: View {
    let model: MenuBarLabelModel
    let icon: ClawdIcon
    var shimmerPhase: Double = 0
    let normalColor: NSColor
    let yellowColor: NSColor
    let redColor: NSColor
    let animateText: Bool
    let backgroundStyle: StatusBarCore.BackgroundStyle = .transparent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The whole label is composited into one NSImage (LabelComposite):
        // MenuBarExtra flattens its label into the status button's single
        // image slot + title, so a multi-view HStack cannot control order
        // or keep more than one image.
        Image(nsImage: LabelComposite.image(model: model, icon: icon,
                                            shimmerPhase: shimmerPhase,
                                            dark: effectiveDark,
                                            normalColor: normalColor,
                                            yellowColor: yellowColor,
                                            redColor: redColor,
                                            animateText: animateText,
                                            backgroundStyle: backgroundStyle))
            .renderingMode(.original)
    }

    private var effectiveDark: Bool {
        Self.effectiveDark(backgroundStyle: backgroundStyle, colorScheme: colorScheme)
    }

    /// A Light background always pairs with dark content and a Dark
    /// background always pairs with light content, regardless of system
    /// appearance; only Transparent follows colorScheme. Static and pure so
    /// it's testable without constructing a SwiftUI environment.
    static func effectiveDark(backgroundStyle: StatusBarCore.BackgroundStyle, colorScheme: ColorScheme) -> Bool {
        switch backgroundStyle {
        case .transparent: colorScheme == .dark
        case .light: false
        case .dark: true
        }
    }
}
