import Foundation
import Security

public struct Account: Equatable, Sendable, Identifiable {
    public let id: String
    public let alias: String?
    public let email: String?
    public let slot: Int?
    public let isActive: Bool
    public let oauthURL: URL
    /// Join key into cux's usage cache; nil for credentials-file accounts
    /// and older cux versions that don't write it into oauth.json.
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
    private struct CuxState: Decodable {
        struct CuxAccount: Decodable {
            let slot: Int
            let email: String
            let alias: String?
        }
        let activeSlot: Int?
        let accounts: [String: CuxAccount]
    }

    public static func discover(cuxRoot: URL, credentialsFile: URL) -> [Account] {
        if let accounts = discoverCux(root: cuxRoot), !accounts.isEmpty {
            return accounts
        }
        if FileManager.default.fileExists(atPath: credentialsFile.path) {
            return [Account(id: "default", alias: nil, email: nil, slot: nil,
                            isActive: true, oauthURL: credentialsFile)]
        }
        return []
    }

    /// Reads only cux metadata (slots, emails, aliases) — never token contents.
    private static func discoverCux(root: URL) -> [Account]? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
              let state = try? JSONDecoder().decode(CuxState.self, from: data) else {
            return nil
        }
        let accountsDir = root.appendingPathComponent("accounts", isDirectory: true)
        let entries = (try? fm.contentsOfDirectory(atPath: accountsDir.path)) ?? []
        return state.accounts.values
            .sorted { $0.slot < $1.slot }
            .compactMap { acct in
                let padded = String(format: "%02d-%@", acct.slot, acct.email)
                let plain = "\(acct.slot)-\(acct.email)"
                guard let dir = entries.first(where: { $0 == padded || $0 == plain }) else {
                    return nil
                }
                let oauth = accountsDir.appendingPathComponent(dir, isDirectory: true)
                    .appendingPathComponent("oauth.json")
                guard fm.fileExists(atPath: oauth.path) else { return nil }
                let orgUuid = (try? Data(contentsOf: oauth)).flatMap(organizationUuid(from:))
                return Account(id: "slot-\(acct.slot)", alias: acct.alias,
                               email: acct.email, slot: acct.slot,
                               isActive: acct.slot == state.activeSlot,
                               oauthURL: oauth, organizationUuid: orgUuid)
            }
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

    /// Non-secret profile metadata from a cux oauth.json.
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

    /// cux v0.2.11+ keeps the real bearer token only in the macOS Keychain
    /// (item labeled "Claude Code-credentials"), not in any slot's
    /// oauth.json. `reader` is injectable so tests can exercise the parsing
    /// path without touching the real Keychain.
    public static func keychainAccessToken(
        service: String = "Claude Code-credentials",
        reader: (String) -> Data? = defaultKeychainReader
    ) -> String? {
        reader(service).flatMap(accessToken(from:))
    }

    public static func defaultKeychainReader(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrLabel as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return data
    }
}
