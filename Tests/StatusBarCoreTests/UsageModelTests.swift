import Foundation
import Testing
@testable import StatusBarCore

@Suite struct UsageParsingTests {
    @Test func parsesFullResponse() throws {
        let json = """
        {"five_hour":{"utilization":70.5,"resets_at":"2026-07-10T05:00:00Z"},
         "seven_day":{"utilization":29}}
        """
        let snap = try #require(UsageSnapshot.parse(Data(json.utf8),
                                                    fetchedAt: Date(timeIntervalSince1970: 0)))
        #expect(snap.fiveHour?.utilization == 70.5)
        #expect(snap.fiveHour?.resetsAt == ISO8601.parse("2026-07-10T05:00:00Z"))
        #expect(snap.sevenDay?.utilization == 29)
        #expect(snap.sevenDay?.resetsAt == nil)
        #expect(snap.fetchedAt == Date(timeIntervalSince1970: 0))
    }

    @Test func integerUtilizationAccepted() throws {
        let json = #"{"five_hour":{"utilization":42}}"#
        let snap = try #require(UsageSnapshot.parse(Data(json.utf8), fetchedAt: .now))
        #expect(snap.fiveHour?.utilization == 42)
        #expect(snap.sevenDay == nil)
    }

    @Test func unknownFieldsIgnored() throws {
        let json = #"{"five_hour":{"utilization":1,"extra":true},"other_window":{}}"#
        let snap = try #require(UsageSnapshot.parse(Data(json.utf8), fetchedAt: .now))
        #expect(snap.fiveHour?.utilization == 1)
    }

    @Test func garbageReturnsNil() {
        #expect(UsageSnapshot.parse(Data("not json".utf8), fetchedAt: .now) == nil)
        #expect(UsageSnapshot.parse(Data("{}".utf8), fetchedAt: .now) == nil)
        #expect(UsageSnapshot.parse(Data(#"{"five_hour":{"utilization":"high"}}"#.utf8),
                                    fetchedAt: .now) == nil)
    }

    @Test func codableRoundTrip() throws {
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 70, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)),
            sevenDay: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_799_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UsageSnapshot.self, from: try encoder.encode(snap))
        #expect(decoded == snap)
    }
}

@Suite struct UsageLevelTests {
    @Test func defaultThresholds() {
        #expect(UsageLevel.level(for: 0) == .green)
        #expect(UsageLevel.level(for: 49.9) == .green)
        #expect(UsageLevel.level(for: 50) == .yellow)
        #expect(UsageLevel.level(for: 79.9) == .yellow)
        #expect(UsageLevel.level(for: 80) == .red)
        #expect(UsageLevel.level(for: 100) == .red)
    }

    @Test func customThresholds() {
        #expect(UsageLevel.level(for: 60, yellowAt: 40, redAt: 70) == .yellow)
        #expect(UsageLevel.level(for: 75, yellowAt: 40, redAt: 70) == .red)
    }
}
