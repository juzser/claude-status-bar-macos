import Foundation

public struct UsageWindow: Codable, Equatable, Sendable {
    public let utilization: Double
    public let resetsAt: Date?

    public init(utilization: Double, resetsAt: Date? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let fetchedAt: Date

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
    }

    /// Tolerant parser for the /api/oauth/usage response. Unknown fields are
    /// ignored; a response with neither window is treated as malformed.
    public static func parse(_ data: Data, fetchedAt: Date) -> UsageSnapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let five = window(from: obj["five_hour"])
        let seven = window(from: obj["seven_day"])
        if five == nil && seven == nil { return nil }
        return UsageSnapshot(fiveHour: five, sevenDay: seven, fetchedAt: fetchedAt)
    }

    private static func window(from any: Any?) -> UsageWindow? {
        guard let dict = any as? [String: Any] else { return nil }
        guard let number = dict["utilization"] as? NSNumber else { return nil }
        let resets = (dict["resets_at"] as? String).flatMap(ISO8601.parse)
        return UsageWindow(utilization: number.doubleValue, resetsAt: resets)
    }
}

public enum UsageLevel: String, Equatable, Sendable {
    case green, yellow, red

    public static func level(for utilization: Double,
                             yellowAt: Double = 50,
                             redAt: Double = 80) -> UsageLevel {
        if utilization >= redAt { return .red }
        if utilization >= yellowAt { return .yellow }
        return .green
    }
}
