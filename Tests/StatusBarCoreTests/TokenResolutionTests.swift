import Foundation
import Testing
@testable import StatusBarCore

private func account(id: String = "acct", isActive: Bool = false) -> Account {
    Account(id: id, alias: nil, email: nil, slot: 1, isActive: isActive,
            oauthURL: URL(fileURLWithPath: "/dev/null"))
}

private func snapshot() -> UsageSnapshot {
    UsageSnapshot(fiveHour: nil, sevenDay: nil, fetchedAt: Date(timeIntervalSinceReferenceDate: 0))
}

@Suite("TokenResolution")
struct TokenResolutionTests {
    @Test("returns the oauth-file token when present, regardless of isActive or cached")
    func resolvesFromOauthFile() {
        let (token, source) = TokenResolution.resolve(
            account: account(isActive: false), cached: snapshot(),
            oauthData: { _ in Data(#"{"claudeAiOauth":{"accessToken":"tok"}}"#.utf8) },
            keychainAccessToken: { Issue.record("should not consult Keychain"); return nil })
        #expect(token == "tok")
        #expect(source == .oauthFile)
    }

    @Test("returns none when oauth is empty and the account isn't active")
    func returnsNoneWhenInactive() {
        let (token, source) = TokenResolution.resolve(
            account: account(isActive: false), cached: nil,
            oauthData: { _ in nil },
            keychainAccessToken: { Issue.record("should not consult Keychain"); return nil })
        #expect(token == nil)
        #expect(source == .none)
    }

    @Test("returns none when oauth is empty, active, but a cached snapshot already exists")
    func returnsNoneWhenCached() {
        let (token, source) = TokenResolution.resolve(
            account: account(isActive: true), cached: snapshot(),
            oauthData: { _ in nil },
            keychainAccessToken: { Issue.record("should not consult Keychain"); return nil })
        #expect(token == nil)
        #expect(source == .none)
    }

    @Test("falls back to the Keychain only when active with no cached snapshot")
    func fallsBackToKeychain() {
        let (token, source) = TokenResolution.resolve(
            account: account(isActive: true), cached: nil,
            oauthData: { _ in nil },
            keychainAccessToken: { "keychain-tok" })
        #expect(token == "keychain-tok")
        #expect(source == .keychainFallback)
    }
}

@Suite("TokenResolutionDiagnostics")
struct TokenResolutionDiagnosticsTests {
    @Test("formats one line per entry with a leading timestamp, never including a token value")
    func formatsEntries() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let text = TokenResolutionDiagnostics.format(
            [
                .init(accountId: "slot-1", isActive: true, organizationUuid: "org-aaa",
                      cacheHit: false, source: .keychainFallback),
                .init(accountId: "slot-2", isActive: false, organizationUuid: nil,
                      cacheHit: true, source: .none),
            ], now: now)
        #expect(text.hasPrefix("timestamp: "))
        #expect(text.contains("slot-1 isActive=true orgUuid=org-aaa cuxCacheHit=false tokenSource=keychainFallback"))
        #expect(text.contains("slot-2 isActive=false orgUuid=nil cuxCacheHit=true tokenSource=none"))
    }

    @Test("write overwrites the file on each call rather than appending")
    func writeOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-resolution-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("token-resolution.log")

        TokenResolutionDiagnostics.write(
            [.init(accountId: "slot-1", isActive: true, organizationUuid: "org-aaa",
                   cacheHit: false, source: .keychainFallback)],
            to: file, now: Date(timeIntervalSinceReferenceDate: 0))
        let first = try String(contentsOf: file, encoding: .utf8)
        #expect(first.contains("slot-1"))

        TokenResolutionDiagnostics.write(
            [.init(accountId: "slot-2", isActive: false, organizationUuid: nil,
                   cacheHit: true, source: .oauthFile)],
            to: file, now: Date(timeIntervalSinceReferenceDate: 1))
        let second = try String(contentsOf: file, encoding: .utf8)
        #expect(!second.contains("slot-1"))
        #expect(second.contains("slot-2"))
    }

    @Test("write creates intermediate directories that don't exist yet")
    func writeCreatesDirectories() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("token-resolution-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nested/token-resolution.log")

        TokenResolutionDiagnostics.write([], to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
