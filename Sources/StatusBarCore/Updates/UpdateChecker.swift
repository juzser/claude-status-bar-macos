import Foundation

/// Checks GitHub Releases for a version newer than the running app, at most
/// once per `minInterval` in the background — mirrors CuxRefresher's shape.
/// Failures are swallowed: a failed check just means the caller sees `nil`,
/// never a user-facing error.
public actor UpdateChecker {
    public static let minInterval: TimeInterval = 86400

    private let fetch: @Sendable () async throws -> ReleaseInfo
    private var lastAttempt: Date?

    public init(fetch: @escaping @Sendable () async throws -> ReleaseInfo = {
        try await GitHubReleaseClient().fetchLatest()
    }) {
        self.fetch = fetch
    }

    /// Checks at most once per `minInterval`. Returns the latest release
    /// only when it's newer than `currentVersion`; otherwise nil (including
    /// when gated by the interval, on fetch failure, or malformed data).
    public func checkIfNeeded(currentVersion: String, now: Date = Date()) async -> ReleaseInfo? {
        if let last = lastAttempt, now.timeIntervalSince(last) < Self.minInterval { return nil }
        lastAttempt = now
        return await attempt(currentVersion: currentVersion)
    }

    /// Bypasses the interval gate for a manual "Check for Updates" click,
    /// and still resets `lastAttempt` so the next automatic loop iteration
    /// doesn't immediately re-fire.
    public func checkNow(currentVersion: String, now: Date = Date()) async -> ReleaseInfo? {
        lastAttempt = now
        return await attempt(currentVersion: currentVersion)
    }

    private func attempt(currentVersion: String) async -> ReleaseInfo? {
        guard let release = try? await fetch() else { return nil }
        guard Self.isNewer(latestTag: release.tagName, currentVersion: currentVersion) else { return nil }
        return release
    }

    /// Strips a leading "v" and compares X.Y.Z components numerically. A
    /// malformed tag on either side (not exactly three integer components)
    /// returns false rather than crashing or producing a false positive.
    public static func isNewer(latestTag: String, currentVersion: String) -> Bool {
        guard let latest = versionComponents(latestTag),
              let current = versionComponents(currentVersion) else { return false }
        for (l, c) in zip(latest, current) {
            if l != c { return l > c }
        }
        return false
    }

    private static func versionComponents(_ raw: String) -> [Int]? {
        var s = raw
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return numbers
    }
}
