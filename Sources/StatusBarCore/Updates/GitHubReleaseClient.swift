import Foundation

public enum ReleaseError: Error, Equatable {
    case rateLimited
    case http(Int)
    case network
    case malformed
}

public protocol ReleaseFetching: Sendable {
    func fetchLatest() async throws -> ReleaseInfo
}

/// Real client for GET /repos/juzser/claude-status-bar-macos/releases/latest.
/// Unauthenticated — GitHub's public rate limit (60 req/hour per IP) easily
/// covers a once-a-day background check plus occasional manual clicks.
public struct GitHubReleaseClient: ReleaseFetching {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: URL(string:
            "https://api.github.com/repos/juzser/claude-status-bar-macos/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ReleaseError.network
        }
        guard let http = response as? HTTPURLResponse else { throw ReleaseError.network }
        switch http.statusCode {
        case 200...299: break
        case 429: throw ReleaseError.rateLimited
        default: throw ReleaseError.http(http.statusCode)
        }
        guard let release = ReleaseInfo.parse(data) else {
            throw ReleaseError.malformed
        }
        return release
    }
}
