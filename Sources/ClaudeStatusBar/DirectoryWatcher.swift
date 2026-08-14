import Foundation

/// Watches one directory for writes via DispatchSource (kqueue under the hood).
/// Calls onChange on the main queue. The directory must exist when init runs.
final class DirectoryWatcher {
    /// Writes are coalesced over this window before `onChange` fires.
    ///
    /// A single session update is several kqueue events, not one: the hook
    /// writes through `AtomicFile.write` (temp file → rename), and Claude Code
    /// touches its own transcript in the same directory. Each raw event made
    /// the app re-read and re-decode *every* session file in the directory, so
    /// one logical change cost several full rescans. 200 ms is short enough to
    /// stay imperceptible on a status bar and long enough to fold a burst into
    /// one rescan.
    static let debounce: DispatchTimeInterval = .milliseconds(200)

    private let source: DispatchSourceFileSystemObject?
    /// Only touched from the main queue — both the event handler and the
    /// scheduled work item run there.
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            source = nil
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        self.source = source
        source.setEventHandler { [weak self] in
            self?.schedule(onChange)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    /// Trailing-edge debounce: each event cancels the previous pending rescan
    /// and re-arms, so a burst of writes settles into a single call.
    private func schedule(_ onChange: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pending = nil
            onChange()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    deinit {
        pending?.cancel()
        source?.cancel()
    }
}
