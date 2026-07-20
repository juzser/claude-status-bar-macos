import Foundation
import Security
import Testing
@testable import StatusBarCore

private func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acct-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct AccountDiscoveryTests {
    @Test func fallsBackToCredentialsFile() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let creds = tmp.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"fake"}}"#.utf8).write(to: creds)
        let accounts = AccountDiscovery.discover(credentialsFile: creds)
        #expect(accounts.count == 1)
        #expect(accounts[0].id == "default")
        #expect(accounts[0].isActive)
        #expect(accounts[0].slot == nil)
        #expect(accounts[0].oauthURL == creds)
    }

    @Test func emptyWhenNoSourceExists() {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let accounts = AccountDiscovery.discover(
            credentialsFile: tmp.appendingPathComponent("none.json"))
        #expect(accounts.isEmpty)
    }
}

@Suite struct AccessTokenTests {
    @Test func nestedShape() {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"fake-abc"}}"#.utf8)
        #expect(AccountDiscovery.accessToken(from: data) == "fake-abc")
    }

    @Test func flatShape() {
        let data = Data(#"{"accessToken":"fake-xyz"}"#.utf8)
        #expect(AccountDiscovery.accessToken(from: data) == "fake-xyz")
    }

    @Test func malformedReturnsNil() {
        #expect(AccountDiscovery.accessToken(from: Data("nope".utf8)) == nil)
        #expect(AccountDiscovery.accessToken(from: Data("{}".utf8)) == nil)
    }
}

@Suite struct OrganizationUuidTests {
    @Test func readsOrganizationUuidWhenPresent() {
        let data = Data(#"{"organizationUuid":"org-1","emailAddress":"a@x.com"}"#.utf8)
        #expect(AccountDiscovery.organizationUuid(from: data) == "org-1")
    }

    @Test func nilWhenMissing() {
        let data = Data(#"{"emailAddress":"a@x.com"}"#.utf8)
        #expect(AccountDiscovery.organizationUuid(from: data) == nil)
    }

    @Test func nilWhenMalformed() {
        #expect(AccountDiscovery.organizationUuid(from: Data("nope".utf8)) == nil)
    }
}

/// SecItemCopyMatching itself can't be exercised in a unit test, so
/// keychainAccessToken takes an injectable reader — these tests cover the
/// parsing/integration path around it, not the real Keychain call.
@Suite struct KeychainAccessTokenTests {
    @Test func returnsTokenParsedFromReaderData() {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"keychain-token"}}"#.utf8)
        let token = AccountDiscovery.keychainAccessToken(
            service: "Claude Code-credentials", reader: { _ in data })
        #expect(token == "keychain-token")
    }

    @Test func passesServiceThroughToReader() {
        var seenService: String?
        _ = AccountDiscovery.keychainAccessToken(
            service: "Claude Code-credentials",
            reader: { service in
                seenService = service
                return nil
            })
        #expect(seenService == "Claude Code-credentials")
    }

    @Test func nilWhenReaderFindsNothing() {
        let token = AccountDiscovery.keychainAccessToken(
            service: "Claude Code-credentials", reader: { _ in nil })
        #expect(token == nil)
    }

    @Test func nilWhenReaderDataIsMalformed() {
        let token = AccountDiscovery.keychainAccessToken(
            service: "Claude Code-credentials", reader: { _ in Data("nope".utf8) })
        #expect(token == nil)
    }
}

/// defaultKeychainReader must never be able to pop an interactive Keychain
/// prompt: unlike LiveCredentialWriter.read (self-heal's own repair path,
/// which legitimately needs to prompt to (re-)establish trust), this read
/// backs the periodic usage-fetch path and runs on every poll cycle from
/// several independent, uncoordinated timer loops in AppState. Without
/// kSecUseAuthenticationUIFail, a burst of those loops firing at once right
/// after wake can each independently trigger their own "ClaudeStatusBar
/// wants to access..." dialog.
@Suite struct DefaultKeychainReaderQueryTests {
    @Test func setsAuthenticationUIFailToAvoidInteractivePrompts() {
        var capturedQuery: [String: Any]?
        _ = AccountDiscovery.performKeychainRead(service: "Claude Code-credentials") { query, _ in
            capturedQuery = query as? [String: Any]
            return errSecItemNotFound
        }
        let authUI = capturedQuery?[kSecUseAuthenticationUI as String] as? String
        #expect(authUI == (kSecUseAuthenticationUIFail as String))
    }

    @Test func returnsNilWhenCopyMatchingFails() {
        let result = AccountDiscovery.performKeychainRead(service: "Claude Code-credentials") { _, _ in
            errSecItemNotFound
        }
        #expect(result == nil)
    }
}

@Suite struct EmailAddressTests {
    @Test func emailAddressReadsFromFlatBlock() {
        let json = #"{"emailAddress":"dev@example.com","organizationUuid":"org-1"}"#
        let data = Data(json.utf8)
        #expect(AccountDiscovery.emailAddress(from: data) == "dev@example.com")
    }

    @Test func emailAddressReturnsNilWhenMissing() {
        let data = Data(#"{"organizationUuid":"org-1"}"#.utf8)
        #expect(AccountDiscovery.emailAddress(from: data) == nil)
    }
}
