import Foundation

public enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }

    public static func string(from date: Date) -> String {
        plain.string(from: date)
    }
}
