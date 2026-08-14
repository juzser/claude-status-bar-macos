import AppKit
import SwiftUI
import StatusBarCore

/// The one view that reads `TickClock`, and therefore the only one SwiftUI
/// re-renders at animation rate. Everything it needs is pulled off
/// `appState` here rather than passed down from the scene body, so the
/// observation dependencies on the tick stop at this view instead of
/// invalidating the whole scene — see `ClaudeStatusBarApp.body`.
struct MenuBarLabelView: View {
    let appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let now = appState.clock.now
        let settings = appState.settings
        // The whole label is composited into one NSImage (LabelComposite):
        // MenuBarExtra flattens its label into the status button's single
        // image slot + title, so a multi-view HStack cannot control order
        // or keep more than one image.
        //
        // The three user colors go through the memoized `cached(hex:)`: they
        // are re-read every frame but change only when the user edits them
        // in Settings, and parsing them fresh minted three NSColors per frame.
        return Image(nsImage: LabelComposite.image(
            model: appState.labelModel(now: now),
            icon: StatusIcon.icon(for: appState.display),
            shimmerPhase: ShimmerText.phase(at: now),
            dark: colorScheme == .dark,
            normalColor: .cached(hex: settings.normalColorHex) ?? .systemGreen,
            yellowColor: .cached(hex: settings.yellowColorHex) ?? .systemYellow,
            redColor: .cached(hex: settings.redColorHex) ?? .systemRed,
            animateText: settings.textAnimationEnabled))
            .renderingMode(.original)
    }
}
