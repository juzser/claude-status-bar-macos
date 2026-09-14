import Foundation
import Security

/// Verifies a filesystem path's code signature before it is allowed to
/// become a `SecTrustedApplication` and be written onto a Keychain item's
/// ACL. Closes SEC-1: `LiveCredentialWriter.performWrite` and
/// `AccountCredentialVault.performRepairWrite` used to feed
/// `SecTrustedApplicationCreateFromPath` any path handed to them with no
/// signature check at all, so whatever binary happened to sit at that path
/// was granted read access to live Claude credentials.
///
/// Per-path-class policy (csb-signing-policy-1): a path is classified by
/// its role, not merely checked against one shared requirement. `.app`
/// (this app's own bundle path) is verified against the RUNNING PROCESS'S
/// OWN designated requirement — "signed the way this process is signed" —
/// so a dev `swift run` build (ad-hoc) admits nothing, and a locally-signed
/// or notarized build admits only its own signer. `.claude` (a path whose
/// last component is `claude`) is verified against a requirement pinned to
/// Anthropic's Developer ID team (`Q6L2SF6YDW`) and bundle identifier
/// (`com.anthropic.claude-code`), so a locally-minted certificate cannot
/// impersonate it. A path in neither class is rejected outright.
public enum TrustedApplicationGate {
    /// A path's role, decided purely by its content (own bundle path vs.
    /// last path component `claude`) — never by directory location.
    public enum PathClass {
        case app
        case claude
    }

    /// Pinned requirement for the `.claude` class. The `certificate
    /// leaf[subject.OU]` clause is REQUIRED: `anchor apple generic` alone
    /// admits any Apple developer account, and the bundle identifier is
    /// attacker-chosen, so only the Developer ID team clause actually pins
    /// Anthropic's signature (csreq-valid, measured 2026-09-11).
    public static let claudeRequirement =
        "anchor apple generic and identifier \"com.anthropic.claude-code\" and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""

    /// The has-a-certificate test applied to SELF before the `.app` class
    /// trusts its own designated requirement (criterion 4 step ii): an
    /// ad-hoc self carries a cdhash-pinned designated requirement that
    /// would otherwise admit byte-identical code, which is "something",
    /// when the fail-safe requires "nothing". This is the same literal
    /// csb-audit-1 shipped as its single shared policy string.
    public static let selfCertificatePrecondition = "certificate leaf[subject.CN] exists"

    /// Full/strict validation: catches resource/nested-code tampering that
    /// a bare validity check would miss, and every architecture in a
    /// universal binary rather than just the one that happens to run first.
    private static let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)

    /// Classifies `path`: `.app` iff it equals `appBundlePath` (both
    /// producers pass `Bundle.main.bundlePath` verbatim); else `.claude`
    /// iff its last path component is exactly `claude` (every
    /// `claudeBinaryCandidates` entry ends in `/claude`); else `nil`.
    /// Equality wins when a path is its own app bundle AND happens to be
    /// named `claude`.
    public static func classify(_ path: String, appBundlePath: String) -> PathClass? {
        if path == appBundlePath { return .app }
        if URL(fileURLWithPath: path).lastPathComponent == "claude" { return .claude }
        return nil
    }

    /// Outcome of verifying a candidate against its path class, exposed
    /// internally (via `@testable import`) so C11-C13's end-to-end wiring
    /// probes can distinguish "no self acquired" from "self ad-hoc" from
    /// "candidate rejected" rather than collapsing every failure to the
    /// same boolean.
    internal enum VerifyOutcome {
        case noSelf
        case selfFailsPrecondition
        case noDesignatedRequirement
        case candidateRejected
        case approved
    }

    /// Acquires the running process's own static code, guarding both
    /// `Security` calls on `errSecSuccess` and force-unwrapping neither
    /// (criterion 13's structural probe).
    internal static func copySelfStaticCode() -> SecStaticCode? {
        var selfCode: SecCode?
        let selfStatus = SecCodeCopySelf([], &selfCode)
        guard selfStatus == errSecSuccess, let selfCode else { return nil }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(selfCode, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else { return nil }
        return staticCode
    }

    private static func requirement(from string: String) -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(string as CFString, [], &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private static func candidateSatisfies(_ path: String, requirement: SecRequirement) -> Bool {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else { return false }
        return SecStaticCodeCheckValidity(staticCode, validationFlags, requirement) == errSecSuccess
    }

    private static func candidateSatisfies(_ path: String, requirementString: String) -> Bool {
        guard let requirement = requirement(from: requirementString) else { return false }
        return candidateSatisfies(path, requirement: requirement)
    }

    /// Sequence for an `.app`-class candidate (criterion 4): (i) `selfCode`
    /// non-nil, else `.noSelf`; (ii) self clears `selfCertificatePrecondition`
    /// (the fail-safe: an ad-hoc self's designated requirement is
    /// cdhash-pinned and would otherwise admit byte-identical code), else
    /// `.selfFailsPrecondition`; (iii) self's own designated requirement is
    /// obtainable, else `.noDesignatedRequirement`; (iv) the candidate
    /// satisfies that requirement, else `.candidateRejected`; otherwise
    /// `.approved`.
    private static func appClassOutcome(candidatePath: String, selfCode: SecStaticCode?) -> VerifyOutcome {
        guard let selfCode else { return .noSelf }
        guard let precondition = requirement(from: selfCertificatePrecondition) else { return .selfFailsPrecondition }
        guard SecStaticCodeCheckValidity(selfCode, validationFlags, precondition) == errSecSuccess else {
            return .selfFailsPrecondition
        }
        var selfRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfCode, [], &selfRequirement) == errSecSuccess,
              let selfRequirement else {
            return .noDesignatedRequirement
        }
        return candidateSatisfies(candidatePath, requirement: selfRequirement) ? .approved : .candidateRejected
    }

    private static func outcome(_ path: String, appBundlePath: String, selfCode: SecStaticCode?) -> VerifyOutcome {
        switch classify(path, appBundlePath: appBundlePath) {
        case .claude:
            return candidateSatisfies(path, requirementString: claudeRequirement) ? .approved : .candidateRejected
        case .app:
            return appClassOutcome(candidatePath: path, selfCode: selfCode)
        case nil:
            return .candidateRejected
        }
    }

    /// Injectable core (criterion 4): `.claude`-class candidates are
    /// verified against the pinned Anthropic requirement; `.app`-class
    /// candidates against `selfCode`'s own designated requirement; a path
    /// in neither class is rejected. Tests inject `selfCode` directly; the
    /// end-to-end wiring for `defaultVerify` is graded by `defaultOutcome`
    /// (criteria 11-13), not here.
    public static func verify(_ path: String, appBundlePath: String, selfCode: SecStaticCode?) -> Bool {
        outcome(path, appBundlePath: appBundlePath, selfCode: selfCode) == .approved
    }

    /// The end-to-end outcome `defaultVerify` reduces to a `Bool`. Self is
    /// acquired INSIDE this function (never injected as a `SecStaticCode`)
    /// so the wiring from `defaultVerify` down to a real
    /// `SecCodeCopySelf`/`SecCodeCopyStaticCode` acquisition is itself
    /// under test. `acquireSelf` is the only injection point, and it
    /// injects the ACQUIRER, not a result.
    internal static func defaultOutcome(
        _ path: String,
        appBundlePath: String = Bundle.main.bundlePath,
        acquireSelf: () -> SecStaticCode? = copySelfStaticCode
    ) -> VerifyOutcome {
        switch classify(path, appBundlePath: appBundlePath) {
        case .claude:
            return candidateSatisfies(path, requirementString: claudeRequirement) ? .approved : .candidateRejected
        case .app:
            return appClassOutcome(candidatePath: path, selfCode: acquireSelf())
        case nil:
            return .candidateRejected
        }
    }

    /// Synchronous, no subprocess: `performWrite`/`performRepairWrite` are
    /// synchronous and called from synchronous contexts (nonfunctional
    /// clause 3). Every repo-declared symbol this reaches is declared in
    /// this file. A pure `Bool` reduction of `defaultOutcome` — it must
    /// never carry a second implementation of its own.
    public static func defaultVerify(_ path: String) -> Bool {
        defaultOutcome(path) == .approved
    }

    /// Default `SecTrustedApplication` factory for both sinks: wraps
    /// `SecTrustedApplicationCreateFromPath`, returning `nil` on failure
    /// exactly as the sinks' inline `compactMap` used to.
    public static func defaultMakeTrustedApplication(_ path: String) -> SecTrustedApplication? {
        var app: SecTrustedApplication?
        SecTrustedApplicationCreateFromPath(path, &app)
        return app
    }

    /// Filters `paths` down to the ones `verify` approves, diagnosing each
    /// rejection through `onReject`. Per-path filtering (functional clause
    /// 3): approved paths pass through; rejected ones are dropped. Returns
    /// `nil` only when `paths` was non-empty and every path was rejected —
    /// the caller must then REFUSE the write, leaving the existing
    /// Keychain item and its ACL untouched (nonfunctional clause 6 — never
    /// leave an ACL naming zero trusted applications). An empty input
    /// returns `[]`, preserving today's system-default-ACL behaviour.
    /// `appBundlePath` is used only to name the rejected path's class in
    /// the diagnostic reason — the accept/reject decision is `verify`'s
    /// alone.
    public static func filter(
        _ paths: [String],
        verify: (String) -> Bool,
        onReject: (String, String) -> Void,
        appBundlePath: String = Bundle.main.bundlePath
    ) -> [String]? {
        guard !paths.isEmpty else { return [] }
        var approved: [String] = []
        for path in paths {
            if verify(path) {
                approved.append(path)
            } else {
                let className: String
                switch classify(path, appBundlePath: appBundlePath) {
                case .app: className = "app"
                case .claude: className = "claude"
                case nil: className = "no path class"
                }
                onReject(path, "per-path-class policy rejected: \(className)")
            }
        }
        return approved.isEmpty ? nil : approved
    }

    // MARK: - Rejection diagnostic channel

    /// Where the production default writes. `AppPaths` is public in
    /// `StatusBarCore` and honours `CLAUDE_STATUS_BAR_HOME`; precedent:
    /// `NativeAccountSwitcher.swift:26` defaults its own diagnostic log URL
    /// in-file the same way. Not settable — the factory below is this
    /// plan's only redirection seam.
    public static let defaultDiagnosticLogURL: URL =
        AppPaths().root.appendingPathComponent("trusted-application-gate.log")

    /// Appends one line to `url`: an ISO-8601 timestamp, the rejected path
    /// and the reason, tab-separated, and nothing else (functional clause
    /// 6 / nonfunctional clause 7). Neither field may itself carry a tab
    /// or a newline; any such character is replaced with a space so the
    /// field count is a property of the writer, not of its inputs.
    /// Best-effort throughout: creates the destination's parent directory
    /// if missing, never throws, never traps, never blocks the credential
    /// path — a failed log must not fail a write.
    public static func writeRejectionDiagnostic(path: String, reason: String, to url: URL) {
        func sanitize(_ field: String) -> String {
            field.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp)\t\(sanitize(path))\t\(sanitize(reason))\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Factory: returns an `onReject`-shaped closure that appends to `url`.
    /// Its whole purpose is that the composition of handler and writer can
    /// be exercised against a temporary URL instead of the operator's
    /// home — `defaultOnReject` below is this factory applied to
    /// `defaultDiagnosticLogURL`, and nothing else in this file redirects it.
    public static func rejectionHandler(writingTo url: URL) -> (String, String) -> Void {
        { path, reason in
            writeRejectionDiagnostic(path: path, reason: reason, to: url)
        }
    }

    /// The production default. No test may invoke this directly — doing so
    /// appends to the operator's real `AppPaths().root`, outside the
    /// worktree (nonfunctional clause 9).
    public static let defaultOnReject: (String, String) -> Void = rejectionHandler(writingTo: defaultDiagnosticLogURL)
}
