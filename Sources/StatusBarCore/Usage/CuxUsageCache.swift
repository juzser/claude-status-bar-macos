import Foundation

/// Reader for cux's own usage cache (~/.cux/runtime/usage-cache.json).
///
/// cux keeps real tokens in the macOS Keychain, so slot oauth.json files
/// carry no token this app could use to hit the usage API. cux's hooks do
/// poll usage themselves and persist it here, keyed by organizationUuid —
/// this reader turns those entries into snapshots we can display.
public enum CuxUsageCache {
    public static func load(file: URL) -> [String: UsageSnapshot] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return parse(data)
    }

    /// Entries without a parsable polled_at or without any usage window are
    /// dropped — no timestamp means no freshness story, no windows means
    /// nothing to show.
    public static func parse(_ data: Data) -> [String: UsageSnapshot] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var result: [String: UsageSnapshot] = [:]
        for (orgUuid, value) in root {
            guard let entry = value as? [String: Any],
                  let polledAt = (entry["polled_at"] as? String).flatMap(ISO8601.parse),
                  let snapshot = UsageSnapshot.parse(object: entry, fetchedAt: polledAt)
            else { continue }
            result[orgUuid] = snapshot
        }
        return result
    }
}
