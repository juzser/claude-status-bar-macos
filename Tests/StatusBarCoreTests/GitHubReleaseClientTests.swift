import Foundation
import Testing
@testable import StatusBarCore

/// Global stub for URLProtocol — one handler at a time, hence .serialized.
/// Named distinctly from UsageClientTests' StubURLProtocol to avoid a
/// same-module redeclaration, and to keep the two suites' static handler
/// state from racing (.serialized only serializes within one suite).
final class GitHubStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct GitHubReleaseClientTests {
    private func makeClient() -> GitHubReleaseClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubStubURLProtocol.self]
        return GitHubReleaseClient(session: URLSession(configuration: config))
    }

    @Test func fetchLatestParsesGoodResponse() async throws {
        GitHubStubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString ==
                     "https://api.github.com/repos/juzser/claude-status-bar-macos/releases/latest")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
            return (200, Data(#"""
            {"tag_name":"v0.1.3","html_url":"https://github.com/juzser/claude-status-bar-macos/releases/tag/v0.1.3"}
            """#.utf8))
        }
        let release = try await makeClient().fetchLatest()
        #expect(release.tagName == "v0.1.3")
        #expect(release.htmlURL == URL(string: "https://github.com/juzser/claude-status-bar-macos/releases/tag/v0.1.3"))
    }

    @Test func statusCodesMapToErrors() async {
        for (status, expected) in [(429, ReleaseError.rateLimited),
                                   (500, ReleaseError.http(500))] {
            GitHubStubURLProtocol.handler = { _ in (status, Data()) }
            await #expect(throws: expected) { try await makeClient().fetchLatest() }
        }
    }

    @Test func garbageBodyIsMalformed() async {
        GitHubStubURLProtocol.handler = { _ in (200, Data("<html>".utf8)) }
        await #expect(throws: ReleaseError.malformed) { try await makeClient().fetchLatest() }
    }

    @Test func transportFailureIsNetwork() async {
        GitHubStubURLProtocol.handler = nil  // startLoading fails -> URLError
        await #expect(throws: ReleaseError.network) { try await makeClient().fetchLatest() }
    }
}
