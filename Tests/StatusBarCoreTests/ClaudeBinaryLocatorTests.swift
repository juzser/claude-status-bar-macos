import Foundation
import Testing
@testable import StatusBarCore

@Suite struct ClaudeBinaryLocatorTests {
    @Test func returnsStaticCandidateWithoutFallingBackToDynamicResolve() async {
        let locator = ClaudeBinaryLocator()
        var dynamicCalled = false
        let path = await locator.resolve(
            staticCandidate: { "/opt/homebrew/bin/claude" },
            dynamicResolve: { dynamicCalled = true; return nil }
        )
        #expect(path == "/opt/homebrew/bin/claude")
        #expect(dynamicCalled == false)
    }

    @Test func fallsBackToDynamicResolveWhenStaticCandidateMisses() async {
        let locator = ClaudeBinaryLocator()
        let path = await locator.resolve(
            staticCandidate: { nil },
            dynamicResolve: { "/Users/ser/.local/bin/claude" }
        )
        #expect(path == "/Users/ser/.local/bin/claude")
    }

    @Test func returnsNilWhenBothStaticAndDynamicMiss() async {
        let locator = ClaudeBinaryLocator()
        let path = await locator.resolve(
            staticCandidate: { nil },
            dynamicResolve: { nil }
        )
        #expect(path == nil)
    }

    @Test func cachesResolvedPathAcrossCalls() async {
        let locator = ClaudeBinaryLocator()
        var staticCallCount = 0
        let first = await locator.resolve(
            staticCandidate: { staticCallCount += 1; return "/bin/claude" },
            dynamicResolve: { nil }
        )
        let second = await locator.resolve(
            staticCandidate: { staticCallCount += 1; return "/bin/claude" },
            dynamicResolve: { nil }
        )
        #expect(first == "/bin/claude")
        #expect(second == "/bin/claude")
        #expect(staticCallCount == 1)
    }

    @Test func cachesNilResultAcrossCalls() async {
        let locator = ClaudeBinaryLocator()
        var dynamicCallCount = 0
        let first = await locator.resolve(
            staticCandidate: { nil },
            dynamicResolve: { dynamicCallCount += 1; return nil }
        )
        let second = await locator.resolve(
            staticCandidate: { nil },
            dynamicResolve: { dynamicCallCount += 1; return nil }
        )
        #expect(first == nil)
        #expect(second == nil)
        #expect(dynamicCallCount == 1)
    }
}
