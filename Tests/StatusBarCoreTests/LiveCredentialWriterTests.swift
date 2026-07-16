import Foundation
import Testing
@testable import StatusBarCore

@Suite struct LiveCredentialWriterTests {
    @Test func readDelegatesToInjectedReader() {
        let result = LiveCredentialWriter.read(reader: { service in
            service == LiveCredentialWriter.service ? Data("token".utf8) : nil
        })
        #expect(result == Data("token".utf8))
    }

    @Test func readReturnsNilWhenReaderReturnsNil() {
        #expect(LiveCredentialWriter.read(reader: { _ in nil }) == nil)
    }

    @Test func writePassesDataTrustedPathsAndServiceThrough() {
        var captured: (Data, [String], String)?
        let ok = LiveCredentialWriter.write(Data("token".utf8), trustedPaths: ["/bin/claude"]) { data, paths, service in
            captured = (data, paths, service)
            return true
        }
        #expect(ok)
        #expect(captured?.0 == Data("token".utf8))
        #expect(captured?.1 == ["/bin/claude"])
        #expect(captured?.2 == LiveCredentialWriter.service)
    }

    @Test func writeFailsWhenWriterFails() {
        let ok = LiveCredentialWriter.write(Data(), trustedPaths: []) { _, _, _ in false }
        #expect(ok == false)
    }

    @Test func trustedPathsDropsNilClaudePath() {
        let paths = LiveCredentialWriter.trustedPaths(thisAppPath: "/Applications/App.app", claudePath: nil)
        #expect(paths == ["/Applications/App.app"])
    }

    @Test func trustedPathsIncludesBothWhenPresent() {
        let paths = LiveCredentialWriter.trustedPaths(thisAppPath: "/Applications/App.app",
                                                       claudePath: "/opt/homebrew/bin/claude")
        #expect(paths == ["/Applications/App.app", "/opt/homebrew/bin/claude"])
    }

    @Test func resolvedClaudePathReturnsFirstExecutableCandidate() {
        let path = LiveCredentialWriter.resolvedClaudePath(
            candidates: ["/usr/local/bin/claude", "/opt/homebrew/bin/claude"],
            isExecutable: { $0 == "/opt/homebrew/bin/claude" }
        )
        #expect(path == "/opt/homebrew/bin/claude")
    }

    @Test func resolvedClaudePathReturnsNilWhenNoCandidateExecutable() {
        let path = LiveCredentialWriter.resolvedClaudePath(candidates: ["/usr/local/bin/claude"],
                                                           isExecutable: { _ in false })
        #expect(path == nil)
    }
}
