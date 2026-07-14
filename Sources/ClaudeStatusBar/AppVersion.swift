import Foundation

/// The running app's version, read from Info.plist. Falls back to "dev"
/// under `swift run`/debug, which has no Info.plist.
enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
