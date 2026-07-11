import Foundation

public enum UsageError: Error, Equatable {
    case unauthorized
    case rateLimited
    case http(Int)
    case network
    case malformed
}

public protocol UsageFetching: Sendable {
    func fetch(token: String) async throws -> UsageSnapshot
}

/// Real client for GET https://api.anthropic.com/api/oauth/usage.
/// The token lives only in the request header — never stored or logged.
public struct UsageClient: UsageFetching {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("claude-code/2.1.197", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.network
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.network }
        switch http.statusCode {
        case 200...299: break
        case 401: throw UsageError.unauthorized
        case 429: throw UsageError.rateLimited
        default: throw UsageError.http(http.statusCode)
        }
        guard let snapshot = UsageSnapshot.parse(data, fetchedAt: Date()) else {
            throw UsageError.malformed
        }
        return snapshot
    }
}
