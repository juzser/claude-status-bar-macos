import Foundation
import Observation

/// The menu bar label's animation heartbeat, deliberately kept *out* of
/// `AppState`.
///
/// `now` changes up to 15 times a second, and `@Observable` invalidates
/// every view that read it. While this lived on `AppState` the reader was
/// the `ClaudeStatusBarApp` scene body itself, so a busy session rebuilt the
/// popover's whole view tree — sessions list, account rows, usage bars — at
/// animation rate even with the popover closed and nothing on screen to
/// show for it. Isolating the clock means only what actually reads `now`
/// (the label, via `MenuBarLabelView`) pays for it.
///
/// A plain `Task` loop, not a `TimelineView`: see `MenuBarTickRate` for the
/// cadence and `PopoverClock` for the re-anchoring trap that rules
/// `.periodic` out here.
@Observable @MainActor
final class TickClock {
    private(set) var now = Date()

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var interval: Duration?

    /// Starts, retargets, or stops the ticker. Called on every
    /// `AppState.reaggregate()`, so the common case is a no-op: a nil
    /// `milliseconds` stops the loop outright, and an unchanged cadence
    /// leaves the running loop alone rather than restarting it (which would
    /// reset the shimmer sweep mid-stride).
    func retarget(milliseconds: Int?) {
        guard let milliseconds else {
            task?.cancel()
            task = nil
            interval = nil
            return
        }
        let wanted = Duration.milliseconds(milliseconds)
        guard task == nil || interval != wanted else { return }
        task?.cancel()
        interval = wanted
        now = Date()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: wanted)
                guard !Task.isCancelled else { return }
                self?.now = Date()
            }
        }
    }
}
