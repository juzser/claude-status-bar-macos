import Foundation
import Testing
@testable import StatusBarCore

/// Mirrors ~/.cux/runtime/usage-cache.json: organizationUuid -> windows + polled_at.
private let fixture = """
{
  "org-aaa": {
    "five_hour": { "utilization": 23, "resets_at": "2026-07-11T12:20:00.130703Z" },
    "seven_day": { "utilization": 65, "resets_at": "2026-07-16T23:00:00.130728Z" },
    "polled_at": "2026-07-11T09:14:33.167178Z"
  },
  "org-bbb": {
    "five_hour": { "utilization": 5 },
    "polled_at": "2026-07-11T09:14:33Z"
  },
  "org-no-windows": { "polled_at": "2026-07-11T09:14:33Z" },
  "org-no-polled-at": { "five_hour": { "utilization": 50 } },
  "acct-ccc|org-ccc": {
    "five_hour": { "utilization": 42 },
    "polled_at": "2026-07-11T09:14:33Z"
  }
}
"""

@Suite struct CuxUsageCacheTests {
    @Test func parsesEntriesKeyedByOrganizationUuid() {
        let cache = CuxUsageCache.parse(Data(fixture.utf8))
        let a = cache["org-aaa"]
        #expect(a?.fiveHour?.utilization == 23)
        #expect(a?.sevenDay?.utilization == 65)
        #expect(a?.fiveHour?.resetsAt == ISO8601.parse("2026-07-11T12:20:00.130703Z"))
        // polled_at (fractional seconds) becomes the snapshot's fetchedAt.
        #expect(a?.fetchedAt == ISO8601.parse("2026-07-11T09:14:33.167178Z"))
        let b = cache["org-bbb"]
        #expect(b?.fiveHour?.utilization == 5)
        #expect(b?.sevenDay == nil)
    }

    @Test func dropsEntriesWithoutWindowsOrTimestamp() {
        let cache = CuxUsageCache.parse(Data(fixture.utf8))
        #expect(cache["org-no-windows"] == nil)
        #expect(cache["org-no-polled-at"] == nil)
        #expect(cache.count == 3)
    }

    /// Newer cux versions key entries as "accountUuid|organizationUuid"
    /// instead of a bare organizationUuid — the join in AppState.usageInputs
    /// looks up by organizationUuid alone, so the compound key must be split.
    @Test func splitsCompoundAccountOrgKey() {
        let cache = CuxUsageCache.parse(Data(fixture.utf8))
        #expect(cache["org-ccc"]?.fiveHour?.utilization == 42)
        #expect(cache["acct-ccc|org-ccc"] == nil)
    }

    /// cux has been observed leaving a stale bare-orgUuid-keyed entry (or a
    /// stale compound accountUuid|orgUuid entry) in the cache alongside a
    /// fresh entry under the other key format for the same org — old writes
    /// are never migrated or pruned when the key format changes. `[String:
    /// Any]` bridged from JSONSerialization iterates in a per-process,
    /// hash-seed-dependent order, so a naive "last one wins" merge silently
    /// keeps whichever entry the loop happens to visit last, not necessarily
    /// the freshest — confirmed against the real ~/.cux/runtime/usage-cache.json,
    /// where this exact collision made the app display two-day-stale
    /// percentages non-deterministically across app relaunches. Many
    /// independently-hashed collisions here make a false pass (by chance
    /// landing in fresh-last order for every single one) astronomically
    /// unlikely, so this exercises the real fix rather than relying on luck.
    @Test func prefersMostRecentEntryAcrossManyKeyCollisions() throws {
        var object: [String: Any] = [:]
        var expected: [String: (utilization: Double, fetchedAt: Date)] = [:]
        for i in 0..<30 {
            let org = "org-collide-\(i)"
            let fresh = "2026-07-15T10:00:\(String(format: "%02d", i))Z"
            let stale = "2026-07-13T04:51:\(String(format: "%02d", i))Z"
            object[org] = ["five_hour": ["utilization": 11], "polled_at": fresh]
            object["acct-old-\(i)|\(org)"] = ["five_hour": ["utilization": 99], "polled_at": stale]
            expected[org] = (11, try #require(ISO8601.parse(fresh)))
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let cache = CuxUsageCache.parse(data)
        for (org, exp) in expected {
            #expect(cache[org]?.fiveHour?.utilization == exp.utilization)
            #expect(cache[org]?.fetchedAt == exp.fetchedAt)
        }
    }

    @Test func malformedDataYieldsEmpty() {
        #expect(CuxUsageCache.parse(Data("nope".utf8)).isEmpty)
        #expect(CuxUsageCache.parse(Data("[1,2]".utf8)).isEmpty)
    }

    @Test func missingFileYieldsEmpty() {
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("cux-cache-\(UUID().uuidString).json")
        #expect(CuxUsageCache.load(file: gone).isEmpty)
    }

    @Test func loadReadsFromDisk() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("cux-cache-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(fixture.utf8).write(to: file)
        #expect(CuxUsageCache.load(file: file).count == 3)
    }
}
