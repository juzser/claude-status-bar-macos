import Foundation
import Testing
@testable import StatusBarCore

@Suite("ReleaseInfo")
struct ReleaseInfoTests {
    @Test("parses a well-formed GitHub release response")
    func parsesGoodResponse() {
        let json = Data(#"""
        {"tag_name":"v0.1.3","html_url":"https://github.com/juzser/claude-status-bar-macos/releases/tag/v0.1.3","body":"notes"}
        """#.utf8)
        let info = ReleaseInfo.parse(json)
        #expect(info?.tagName == "v0.1.3")
        #expect(info?.htmlURL == URL(string: "https://github.com/juzser/claude-status-bar-macos/releases/tag/v0.1.3"))
    }

    @Test("returns nil when tag_name is missing")
    func missingTagName() {
        let json = Data(#"{"html_url":"https://example.com/release"}"#.utf8)
        #expect(ReleaseInfo.parse(json) == nil)
    }

    @Test("returns nil when tag_name is empty")
    func emptyTagName() {
        let json = Data(#"{"tag_name":"","html_url":"https://example.com/release"}"#.utf8)
        #expect(ReleaseInfo.parse(json) == nil)
    }

    @Test("returns nil when html_url is missing")
    func missingHTMLURL() {
        let json = Data(#"{"tag_name":"v0.1.3"}"#.utf8)
        #expect(ReleaseInfo.parse(json) == nil)
    }

    @Test("returns nil when html_url is not a valid URL string")
    func malformedURL() {
        let json = Data(#"{"tag_name":"v0.1.3","html_url":""}"#.utf8)
        #expect(ReleaseInfo.parse(json) == nil)
    }

    @Test("returns nil for garbage input")
    func garbageInput() {
        #expect(ReleaseInfo.parse(Data("<html>".utf8)) == nil)
    }
}
