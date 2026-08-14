import Foundation

/// How often the menu bar label needs re-rendering while a session is busy.
///
/// Every tick re-runs the entire label pipeline — text layout, icon frame
/// pick, compositing the whole label into one `NSImage` — so this interval
/// sets the app's idle CPU floor for as long as any session is working. It
/// lives here, pure and in the tested target, because it is the single
/// highest-leverage number in the app and shouldn't be buried in a view.
public enum MenuBarTickRate {
    /// Sub-second cadence for styles that put activity text on the bar. Both
    /// things moving at that scale are comfortably oversampled at 15 fps: the
    /// shimmer sweep is continuous (one pass per `ShimmerText.period`, 1.6 s)
    /// and the baked icon animation is 8 frames over that same period, i.e.
    /// only 5 frame changes a second. This ran at 30 fps (33 ms) before,
    /// which doubled the cost of every one of those pipeline stages for no
    /// visible difference.
    public static let animatedMilliseconds = 66

    /// Styles with no activity text have nothing sub-second on screen, so
    /// they tick only fast enough to keep the elapsed counter honest.
    public static let staticMilliseconds = 1_000

    /// Interval between label re-renders, or nil when nothing is animating
    /// and the ticker should stop outright rather than idle.
    ///
    /// `.iconOnly` and `.compact` suppress activity text entirely (see the
    /// `style != .iconOnly, style != .compact` guard in `MenuBarText.model`),
    /// which is exactly what makes them the 1 Hz cases.
    public static func milliseconds(busy: Bool, style: DisplayStyle) -> Int? {
        guard busy else { return nil }
        switch style {
        case .iconOnly, .compact: return staticMilliseconds
        case .percent, .textFirst, .full: return animatedMilliseconds
        }
    }
}
