import Foundation

/// Resolves the real `claude` binary path when `LiveCredentialWriter`'s
/// static candidate list misses it — nvm-installed npm globals, the curl
/// installer's `~/.local/bin`, and other version-manager shims all live
/// outside that list. Falls back to `command -v claude` run through
/// `InteractiveShellRunner` so it sees the same PATH the user's own
/// terminal would.
///
/// Caches the resolved path (including a miss) for the actor's lifetime:
/// self-heal runs once per launch and every account switch would otherwise
/// re-shell-out to resolve the same answer. `ClaudeBinaryLocator.shared` is
/// long-lived for the app's process lifetime, so a `claude` installed
/// mid-session isn't picked up until the next launch — an acceptable
/// tradeoff against re-shelling-out on every switch.
public actor ClaudeBinaryLocator {
    public static let shared = ClaudeBinaryLocator()

    private var hasResolved = false
    private var cachedPath: String?

    public init() {}

    public func resolve(
        staticCandidate: () -> String? = { LiveCredentialWriter.resolvedClaudePath() },
        dynamicResolve: () async -> String? = {
            await InteractiveShellRunner.captureOutput(binary: "command", arguments: ["-v", "claude"], timeout: 5)
        }
    ) async -> String? {
        if hasResolved {
            return cachedPath
        }
        let resolved: String?
        if let candidate = staticCandidate() {
            resolved = candidate
        } else {
            resolved = await dynamicResolve()
        }
        cachedPath = resolved
        hasResolved = true
        return resolved
    }
}
