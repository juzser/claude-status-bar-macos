import Foundation
import Testing
@testable import StatusBarCore

private func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("acct-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Fixture ~/.cux tree with two accounts (zero-padded dir for slot 1,
/// unpadded for slot 2 — discovery must accept both namings).
private func makeCuxFixture(in root: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("accounts/01-a@x.com"),
                           withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("accounts/2-b@y.com"),
                           withIntermediateDirectories: true)
    let state = """
    {"activeSlot":1,"accounts":{
      "1":{"slot":1,"email":"a@x.com","alias":"ser","uuid":"u1","addedAt":"2026-01-01T00:00:00Z"},
      "2":{"slot":2,"email":"b@y.com","alias":"oe"}}}
    """
    try Data(state.utf8).write(to: root.appendingPathComponent("state.json"))
    // Slot 1 mirrors current cux: profile metadata only, no token keys.
    try Data(#"{"organizationUuid":"org-1","emailAddress":"a@x.com"}"#.utf8)
        .write(to: root.appendingPathComponent("accounts/01-a@x.com/oauth.json"))
    try Data(#"{"accessToken":"fake-token-2"}"#.utf8)
        .write(to: root.appendingPathComponent("accounts/2-b@y.com/oauth.json"))
}

@Suite struct AccountDiscoveryTests {
    @Test func discoversCuxAccountsSortedBySlot() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cux = tmp.appendingPathComponent("cux", isDirectory: true)
        try makeCuxFixture(in: cux)
        let accounts = AccountDiscovery.discover(
            cuxRoot: cux, credentialsFile: tmp.appendingPathComponent("none.json"))
        #expect(accounts.count == 2)
        #expect(accounts[0].id == "slot-1")
        #expect(accounts[0].alias == "ser")
        #expect(accounts[0].email == "a@x.com")
        #expect(accounts[0].isActive)
        #expect(accounts[0].oauthURL.path.hasSuffix("accounts/01-a@x.com/oauth.json"))
        #expect(accounts[1].id == "slot-2")
        #expect(!accounts[1].isActive)
        #expect(accounts[1].oauthURL.path.hasSuffix("accounts/2-b@y.com/oauth.json"))
    }

    /// The org uuid is the join key into cux's usage cache; oauth.json files
    /// without one (older cux) must still discover, with a nil uuid.
    @Test func readsOrganizationUuidFromOauthMetadata() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cux = tmp.appendingPathComponent("cux", isDirectory: true)
        try makeCuxFixture(in: cux)
        let accounts = AccountDiscovery.discover(
            cuxRoot: cux, credentialsFile: tmp.appendingPathComponent("none.json"))
        #expect(accounts[0].organizationUuid == "org-1")
        #expect(accounts[1].organizationUuid == nil)
    }

    @Test func skipsAccountWithoutTokenFile() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cux = tmp.appendingPathComponent("cux", isDirectory: true)
        try makeCuxFixture(in: cux)
        try FileManager.default.removeItem(
            at: cux.appendingPathComponent("accounts/2-b@y.com/oauth.json"))
        let accounts = AccountDiscovery.discover(
            cuxRoot: cux, credentialsFile: tmp.appendingPathComponent("none.json"))
        #expect(accounts.map(\.id) == ["slot-1"])
    }

    @Test func fallsBackToCredentialsFile() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let creds = tmp.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"fake"}}"#.utf8).write(to: creds)
        let accounts = AccountDiscovery.discover(
            cuxRoot: tmp.appendingPathComponent("no-cux"), credentialsFile: creds)
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
            cuxRoot: tmp.appendingPathComponent("no-cux"),
            credentialsFile: tmp.appendingPathComponent("none.json"))
        #expect(accounts.isEmpty)
    }

    @Test func malformedStateFallsBackToCredentials() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cux = tmp.appendingPathComponent("cux", isDirectory: true)
        try FileManager.default.createDirectory(at: cux, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: cux.appendingPathComponent("state.json"))
        let creds = tmp.appendingPathComponent(".credentials.json")
        try Data(#"{"accessToken":"fake"}"#.utf8).write(to: creds)
        let accounts = AccountDiscovery.discover(cuxRoot: cux, credentialsFile: creds)
        #expect(accounts.map(\.id) == ["default"])
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
