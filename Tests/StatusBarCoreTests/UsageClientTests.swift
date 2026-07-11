import Foundation
import Testing
@testable import StatusBarCore

/// Global stub for URLProtocol — one handler at a time, hence .serialized.
final class StubURLProtocol: URLProtocol {
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

@Suite(.serialized) struct UsageClientTests {
    private func makeClient() -> UsageClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return UsageClient(session: URLSession(configuration: config))
    }

    @Test func fetchParsesGoodResponse() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.197")
            return (200, Data(#"{"five_hour":{"utilization":42},"seven_day":{"utilization":7}}"#.utf8))
        }
        let snapshot = try await makeClient().fetch(token: "fake-token")
        #expect(snapshot.fiveHour?.utilization == 42)
        #expect(snapshot.sevenDay?.utilization == 7)
    }

    @Test func statusCodesMapToErrors() async {
        for (status, expected) in [(401, UsageError.unauthorized),
                                   (429, UsageError.rateLimited),
                                   (500, UsageError.http(500))] {
            StubURLProtocol.handler = { _ in (status, Data()) }
            await #expect(throws: expected) { try await makeClient().fetch(token: "fake") }
        }
    }

    @Test func garbageBodyIsMalformed() async {
        StubURLProtocol.handler = { _ in (200, Data("<html>".utf8)) }
        await #expect(throws: UsageError.malformed) { try await makeClient().fetch(token: "fake") }
    }

    @Test func transportFailureIsNetwork() async {
        StubURLProtocol.handler = nil  // startLoading fails -> URLError
        await #expect(throws: UsageError.network) { try await makeClient().fetch(token: "fake") }
    }
}
