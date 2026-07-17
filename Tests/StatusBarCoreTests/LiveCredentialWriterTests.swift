import Foundation
import Security
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

    // MARK: - isAlreadyTrusted

    @Test func isAlreadyTrustedDelegatesToInjectedProber() {
        let result = LiveCredentialWriter.isAlreadyTrusted(prober: { service in
            service == LiveCredentialWriter.service
        })
        #expect(result)
    }

    @Test func isAlreadyTrustedReturnsFalseWhenProberFails() {
        #expect(LiveCredentialWriter.isAlreadyTrusted(prober: { _ in false }) == false)
    }

    // MARK: - performWrite

    @Test func performWriteUpdatesInPlaceWhenItemExists() {
        var capturedQuery: [String: Any]?
        var capturedUpdateAttributes: [String: Any]?
        var addCalled = false

        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: [],
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { query, attributes in
                capturedQuery = query as? [String: Any]
                capturedUpdateAttributes = attributes as? [String: Any]
                return errSecSuccess
            },
            add: { _, _ in
                addCalled = true
                return errSecSuccess
            }
        )

        #expect(ok)
        #expect(addCalled == false)
        #expect(capturedQuery?[kSecAttrService as String] as? String == LiveCredentialWriter.service)
        #expect(capturedQuery?[kSecAttrAccount as String] as? String == "ser")
        #expect(capturedQuery?[kSecAttrLabel as String] as? String == LiveCredentialWriter.service)
        #expect(capturedUpdateAttributes?[kSecValueData as String] as? Data == Data("token".utf8))
    }

    @Test func performWriteFallsBackToAddWhenItemMissing() {
        var capturedAddAttributes: [String: Any]?

        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: [],
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { _, _ in errSecItemNotFound },
            add: { attributes, _ in
                capturedAddAttributes = attributes as? [String: Any]
                return errSecSuccess
            }
        )

        #expect(ok)
        #expect(capturedAddAttributes?[kSecAttrService as String] as? String == LiveCredentialWriter.service)
        #expect(capturedAddAttributes?[kSecAttrAccount as String] as? String == "ser")
        #expect(capturedAddAttributes?[kSecValueData as String] as? Data == Data("token".utf8))
    }

    @Test func performWriteFailsWithoutFallingBackOnOtherUpdateErrors() {
        var addCalled = false

        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: [],
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { _, _ in errSecAuthFailed },
            add: { _, _ in
                addCalled = true
                return errSecSuccess
            }
        )

        #expect(ok == false)
        #expect(addCalled == false)
    }

    @Test func performWriteReturnsFalseWhenAddFallbackFails() {
        let ok = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: [],
            service: LiveCredentialWriter.service,
            account: "ser",
            update: { _, _ in errSecItemNotFound },
            add: { _, _ in errSecDuplicateItem }
        )

        #expect(ok == false)
    }
}
