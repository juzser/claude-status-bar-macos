import Foundation

/// Watches one directory for writes via DispatchSource (kqueue under the hood).
/// Calls onChange on the main queue. The directory must exist when init runs.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            source = nil
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }
}
