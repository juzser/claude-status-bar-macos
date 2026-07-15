import Foundation

/// Which branch of the token-resolution decision produced a token — tracked
/// so a poll cycle can log which one fired instead of just the resulting
/// token. The Keychain-fallback branch firing when `cached` unexpectedly
/// reads back nil for an account cux has already cached is the leading
/// hypothesis for the still-unexplained intermittent Keychain re-prompt.
public enum TokenSource: String, Sendable {
    case oauthFile
    case keychainFallback
    case none
}

/// Extracted from AppState.token(for:cached:) so the same decision can be
/// both made and observed: production needs the token, diagnostics need to
/// know which branch produced it, without ever logging the token itself.
public enum TokenResolution {
    /// cux v0.2.11+ keeps the real token only in the Keychain, never in a
    /// slot's oauth.json — but cux swaps just the *active* slot's token into
    /// the Keychain, so the fallback is gated on `isActive` to avoid
    /// misattributing that token to other, inactive accounts. It's further
    /// gated on `cached == nil`: cux rewrites the shared Keychain item on
    /// every `cux switch`, resetting macOS's "Always Allow" grant for it, so
    /// touching the Keychain is what actually re-prompts the user. Once cux
    /// has cached anything for this account's org there's nothing left for
    /// the Keychain read to buy beyond a fresher percentage, at the cost of
    /// a prompt on every poll cycle.
    public static func resolve(
        account: Account,
        cached: UsageSnapshot?,
        oauthData: (URL) -> Data? = { try? Data(contentsOf: $0) },
        keychainAccessToken: () -> String? = { AccountDiscovery.keychainAccessToken() }
    ) -> (token: String?, source: TokenSource) {
        if let data = oauthData(account.oauthURL),
           let token = AccountDiscovery.accessToken(from: data) {
            return (token, .oauthFile)
        }
        guard account.isActive, cached == nil else { return (nil, .none) }
        return (keychainAccessToken(), .keychainFallback)
    }
}

/// One poll cycle's token-resolution decisions, written to give the
/// still-unexplained intermittent Keychain re-prompt real evidence: if
/// `tokenSource=keychainFallback` shows up here right when the prompt fires,
/// and `orgUuid` or `cuxCacheHit` is unexpectedly nil/false for an account
/// cux has already cached, that confirms the race hypothesis (a transient
/// nil from a read racing cux's own rewrite of oauth.json or
/// usage-cache.json) instead of leaving it a guess. Never includes a token
/// value, per this app's rule that tokens are read at request time only and
/// never logged.
public enum TokenResolutionDiagnostics {
    public struct Entry: Sendable {
        public let accountId: String
        public let isActive: Bool
        public let organizationUuid: String?
        public let cacheHit: Bool
        public let source: TokenSource

        public init(accountId: String, isActive: Bool, organizationUuid: String?,
                    cacheHit: Bool, source: TokenSource) {
            self.accountId = accountId
            self.isActive = isActive
            self.organizationUuid = organizationUuid
            self.cacheHit = cacheHit
            self.source = source
        }
    }

    static func format(_ entries: [Entry], now: Date) -> String {
        var lines = ["timestamp: \(ISO8601DateFormatter().string(from: now))"]
        lines += entries.map { entry in
            "\(entry.accountId) isActive=\(entry.isActive) "
                + "orgUuid=\(entry.organizationUuid ?? "nil") "
                + "cuxCacheHit=\(entry.cacheHit) tokenSource=\(entry.source.rawValue)"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Overwrites `url` (not append) — only the most recent poll cycle's
    /// decisions matter, mirroring CuxShellInvoker's diagnosticLog. Silently
    /// no-ops on filesystem errors: diagnostics must never be able to fail a
    /// poll cycle.
    public static func write(_ entries: [Entry], to url: URL, now: Date = Date()) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? format(entries, now: now).write(to: url, atomically: true, encoding: .utf8)
    }
}
