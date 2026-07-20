import Foundation
import Security

public struct Account: Equatable, Sendable, Identifiable {
    public let id: String
    public let alias: String?
    public let email: String?
    public let slot: Int?
    public let isActive: Bool
    public let oauthURL: URL
    /// Org identifier read from an account's oauth.json (see
    /// `organizationUuid(from:)`), when known. Serves as the account-identity
    /// join key elsewhere — e.g. `AccountCapture` uses it to match a freshly
    /// captured login to an already-tracked native account. Nil for the
    /// plain credentials-file account `discover(credentialsFile:)` returns,
    /// which has no oauth.json to read one from.
    public let organizationUuid: String?

    public init(id: String, alias: String?, email: String?, slot: Int?,
                isActive: Bool, oauthURL: URL, organizationUuid: String? = nil) {
        self.id = id
        self.alias = alias
        self.email = email
        self.slot = slot
        self.isActive = isActive
        self.oauthURL = oauthURL
        self.organizationUuid = organizationUuid
    }
}

public enum AccountDiscovery {
    /// Falls back to a single default account backed directly by the
    /// `claude`-managed credentials file when no native accounts have been
    /// captured yet (see `AppState.resolveAccounts()`, which prefers
    /// `NativeAccountStore` and only calls this as the pre-native-account
    /// fallback).
    public static func discover(credentialsFile: URL) -> [Account] {
        guard FileManager.default.fileExists(atPath: credentialsFile.path) else {
            return []
        }
        return [Account(id: "default", alias: nil, email: nil, slot: nil,
                        isActive: true, oauthURL: credentialsFile)]
    }

    /// Extracts the bearer token from an oauth/credentials JSON file.
    /// Accepts both {"claudeAiOauth":{"accessToken":…}} and {"accessToken":…}.
    public static func accessToken(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let nested = obj["claudeAiOauth"] as? [String: Any],
           let token = nested["accessToken"] as? String {
            return token
        }
        return obj["accessToken"] as? String
    }

    /// Non-secret profile metadata from an oauth/credentials JSON file: the
    /// org uuid, when present.
    public static func organizationUuid(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["organizationUuid"] as? String
    }

    /// Extracts the email address from the oauthAccount block in ~/.claude.json.
    public static func emailAddress(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj["emailAddress"] as? String
    }

    /// Reads the live "Claude Code-credentials" Keychain item — the same
    /// item `claude` and `NativeAccountSwitcher` write to for the currently
    /// active account. Native (slot) accounts don't carry a token in their
    /// own oauth.json (`NativeAccountStore.toAccount` points `oauthURL` at
    /// `/dev/null`), so this is their fallback source for one. `reader` is
    /// injectable so tests can exercise the parsing path without touching
    /// the real Keychain.
    public static func keychainAccessToken(
        service: String = "Claude Code-credentials",
        reader: (String) -> Data? = defaultKeychainReader
    ) -> String? {
        reader(service).flatMap(accessToken(from:))
    }

    public static func defaultKeychainReader(service: String) -> Data? {
        performKeychainRead(service: service)
    }

    /// Uses `kSecUseAuthenticationUIFail` so this read can never pop an
    /// interactive Keychain prompt — unlike `LiveCredentialWriter.read`
    /// (self-heal's own repair path, which legitimately needs to prompt to
    /// (re-)establish trust), this read backs the periodic usage-fetch path
    /// and runs on every poll cycle from several independent, uncoordinated
    /// timer loops in `AppState` (`pollTask`, `captureTask`,
    /// `wakeObserver`). Without this, a burst of those loops firing at once
    /// right after wake — each still needing to establish trust — could each
    /// independently trigger their own "ClaudeStatusBar wants to access..."
    /// dialog. `copyMatching` is injectable so tests can capture the query
    /// without touching the real Keychain.
    static func performKeychainRead(
        service: String,
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    ) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        guard copyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }
}
