import Foundation
import Observation

/// 1 Hz clock for the popover's relative timestamps ("2m ago", elapsed
/// counters), running only while the popover is actually open.
///
/// This replaces a `TimelineView(.periodic(from: .now, by: 1))`, the same
/// schedule `CLAUDE.md` documents as a trap for the menu bar label but which
/// the popover still had: `.now` is re-evaluated on every `body` call, so each
/// render re-anchors the schedule and its first entry — at `.now` itself — is
/// always already due, which is how that trap turns into a runaway render loop
/// once anything else invalidates the view at speed.
///
/// Driven by `.task`, so the cadence is fixed rather than render-derived, and
/// SwiftUI cancels it when the popover closes instead of leaving a timer
/// ticking behind a window nobody can see.
@Observable @MainActor
final class PopoverClock {
    private(set) var now = Date()

    /// Re-stamps `now` immediately: the popover may have been closed for
    /// hours, and its rows would otherwise render against a stale date for
    /// up to a second after opening.
    func run() async {
        now = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            now = Date()
        }
    }
}
