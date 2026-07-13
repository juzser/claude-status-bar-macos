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
  "org-no-polled-at": { "five_hour": { "utilization": 50 } }
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
        #expect(cache.count == 2)
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
        #expect(CuxUsageCache.load(file: file).count == 2)
    }
}
