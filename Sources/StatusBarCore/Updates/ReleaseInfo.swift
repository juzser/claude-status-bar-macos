import Foundation

public struct ReleaseInfo: Codable, Equatable, Sendable {
    public let tagName: String
    public let htmlURL: URL

    public init(tagName: String, htmlURL: URL) {
        self.tagName = tagName
        self.htmlURL = htmlURL
    }

    /// Tolerant parser for GitHub's /releases/latest response. Only
    /// `tag_name` and `html_url` are required; every other field is ignored.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let tagName = obj["tag_name"] as? String, !tagName.isEmpty else { return nil }
        guard let urlString = obj["html_url"] as? String, let url = URL(string: urlString) else {
            return nil
        }
        return ReleaseInfo(tagName: tagName, htmlURL: url)
    }
}
