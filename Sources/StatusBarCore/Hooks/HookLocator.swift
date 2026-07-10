import Foundation

/// The hook binary ships inside the app bundle next to the main executable.
public func defaultHookBinary(appExecutable: URL?) -> URL? {
    appExecutable?.deletingLastPathComponent().appendingPathComponent("claude-status-hook")
}
