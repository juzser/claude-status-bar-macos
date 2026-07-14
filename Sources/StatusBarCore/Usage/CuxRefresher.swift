import Foundation

/// Asks the `cux` CLI to repoll usage before the app reads its cache.
///
/// cux slot accounts carry no OAuth token (their oauth.json holds only
/// profile metadata), so the app cannot fetch usage itself for them — it can
/// only mirror `~/.cux/runtime/usage-cache.json`. cux normally refreshes that
/// cache just once per session, which leaves the menu bar showing hours-stale
/// numbers. Running `cux usage refresh` before each poll keeps the mirror
/// current. Failures are swallowed: a stale cache is still better than none.
public actor CuxRefresher {
    /// GUI apps launched by LaunchServices get a bare PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`), so probe absolute paths.
    public static let binaryCandidates = ["/opt/homebrew/bin/cux", "/usr/local/bin/cux"]
    public static let minInterval: TimeInterval = 60
    public static let timeout: TimeInterval = 10

    private let candidates: [String]
    private let isExecutable: @Sendable (String) -> Bool
    private let run: @Sendable (String) async -> Bool
    private var lastAttempt: Date?

    public init(candidates: [String] = CuxRefresher.binaryCandidates,
                isExecutable: @escaping @Sendable (String) -> Bool = {
                    FileManager.default.isExecutableFile(atPath: $0)
                },
                run: @escaping @Sendable (String) async -> Bool = {
                    await CuxRefresher.invoke(binary: $0, timeout: CuxRefresher.timeout)
                }) {
        self.candidates = candidates
        self.isExecutable = isExecutable
        self.run = run
    }

    /// Runs `cux usage refresh` when any account is cux-managed, at most once
    /// per `minInterval`. Failed attempts also count against the interval so a
    /// broken CLI is not hammered every poll.
    public func refreshIfNeeded(accounts: [Account], now: Date = Date()) async {
        guard accounts.contains(where: { $0.slot != nil }) else { return }
        if let last = lastAttempt, now.timeIntervalSince(last) < Self.minInterval { return }
        guard let binary = candidates.first(where: isExecutable) else { return }
        lastAttempt = now
        _ = await run(binary)
    }

    /// Runs `<binary> usage refresh` via `CuxShellInvoker`, discarding output.
    /// Returns true only on exit status 0. `environment` is nil in
    /// production (inherit) — tests override it to exercise PATH resolution
    /// hermetically.
    public static func invoke(binary: String, timeout: TimeInterval,
                              environment: [String: String]? = nil) async -> Bool {
        await CuxShellInvoker.invoke(binary: binary, arguments: ["usage", "refresh"],
                                     timeout: timeout, environment: environment)
    }
}
