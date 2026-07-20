import Foundation

/// Which branch of the token-resolution decision produced a token — tracked
/// so a poll cycle can log which one fired instead of just the resulting
/// token. The Keychain-fallback branch used to be able to trigger an
/// interactive Keychain prompt from several independent poll loops at once
/// right after wake (see `AccountDiscovery.performKeychainRead`'s doc
/// comment) — fixed by making that read non-interactive, but the source
/// tracking here stays useful for spotting future regressions.
public enum TokenSource: String, Sendable {
    case oauthFile
    case keychainFallback
    case vaultBackup
    case none
}

/// Extracted from AppState.usageInputs(_:) so the same decision can be
/// both made and observed: production needs the token, diagnostics need to
/// know which branch produced it, without ever logging the token itself.
public enum TokenResolution {
    /// Only the active account's credentials live in the shared
    /// `"Claude Code-credentials"` Keychain item — both the `claude` CLI and
    /// this app's `NativeAccountSwitcher` (see
    /// `Sources/StatusBarCore/Accounts/NativeAccountSwitcher.swift`) write to
    /// that one shared item when switching the active account. So the
    /// Keychain fallback is gated on `isActive`: reading it for an inactive
    /// account would misattribute whatever token currently sits in that
    /// shared item to the wrong account.
    ///
    /// An inactive native account has no live source at all otherwise — its
    /// `oauthURL` is a `/dev/null` placeholder (see `NativeAccountStore`) —
    /// so it falls back to its own snapshot in `AccountCredentialVault`,
    /// written by `NativeAccountSwitcher.switchTo` every time it stops being
    /// the active account. Without this, an inactive account's usage can
    /// never be refreshed at all until it's switched back to.
    public static func resolve(
        account: Account,
        oauthData: (URL) -> Data? = { try? Data(contentsOf: $0) },
        keychainAccessToken: () -> String? = { AccountDiscovery.keychainAccessToken() },
        vaultBackup: (String) -> CredentialBackup? = { AccountCredentialVault.read(accountId: $0) }
    ) -> (token: String?, source: TokenSource) {
        if let data = oauthData(account.oauthURL),
           let token = AccountDiscovery.accessToken(from: data) {
            return (token, .oauthFile)
        }
        guard account.isActive else {
            if let backup = vaultBackup(account.id),
               let token = AccountDiscovery.accessToken(from: backup.liveCredentials) {
                return (token, .vaultBackup)
            }
            return (nil, .none)
        }
        return (keychainAccessToken(), .keychainFallback)
    }
}

/// One poll cycle's token-resolution decisions, written so future Keychain
/// prompt reports have real evidence to check instead of a guess: if
/// `tokenSource=keychainFallback` shows up here right when a prompt fires,
/// and `orgUuid` is unexpectedly nil for an account that should already have
/// one, that's a real clue. Never includes a token value, per this app's
/// rule that tokens are read at request time only and never logged.
public enum TokenResolutionDiagnostics {
    public struct Entry: Sendable {
        public let accountId: String
        public let isActive: Bool
        public let organizationUuid: String?
        public let source: TokenSource

        public init(accountId: String, isActive: Bool, organizationUuid: String?,
                    source: TokenSource) {
            self.accountId = accountId
            self.isActive = isActive
            self.organizationUuid = organizationUuid
            self.source = source
        }
    }

    static func format(_ entries: [Entry], now: Date) -> String {
        var lines = ["timestamp: \(ISO8601DateFormatter().string(from: now))"]
        lines += entries.map { entry in
            "\(entry.accountId) isActive=\(entry.isActive) "
                + "orgUuid=\(entry.organizationUuid ?? "nil") "
                + "tokenSource=\(entry.source.rawValue)"
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Overwrites `url` (not append) — only the most recent poll cycle's
    /// decisions matter, mirroring InteractiveShellRunner's diagnosticLog.
    /// Silently no-ops on filesystem errors: diagnostics must never be able
    /// to fail a poll cycle.
    public static func write(_ entries: [Entry], to url: URL, now: Date = Date()) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? format(entries, now: now).write(to: url, atomically: true, encoding: .utf8)
    }
}
