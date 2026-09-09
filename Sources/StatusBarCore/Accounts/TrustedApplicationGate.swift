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
/// Policy: `anchor exists` — satisfied by any code carrying a certificate
/// chain (including this repo's self-signed `ClaudeStatusBar Local
/// Signing` leaf), unsatisfied by ad-hoc code, which carries no
/// certificates at all. Deliberately does NOT require an Apple anchor or a
/// Team Identifier: this app's own shipped bundle has
/// `TeamIdentifier=not set` (measured 2026-09-07), so either of those
/// would reject the app's own bundle and break self-heal for every build
/// this repo produces.
public enum TrustedApplicationGate {
    /// The exact requirement string passed to `SecRequirementCreateWithString`.
    /// Exposed so tests can assert the policy directly (criterion 6a).
    public static let policyRequirement = "anchor exists"

    /// Full/strict validation: catches resource/nested-code tampering that
    /// a bare validity check would miss, and every architecture in a
    /// universal binary rather than just the one that happens to run first.
    private static let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)

    /// Synchronous, no subprocess: `performWrite`/`performRepairWrite` are
    /// synchronous and called from synchronous contexts (nonfunctional
    /// clause 3). Every repo-declared symbol this reaches is declared in
    /// this file.
    public static func defaultVerify(_ path: String) -> Bool {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else { return false }

        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            policyRequirement as CFString, [], &requirement)
        guard requirementStatus == errSecSuccess, let requirement else { return false }

        let validityStatus = SecStaticCodeCheckValidity(staticCode, validationFlags, requirement)
        return validityStatus == errSecSuccess
    }

    /// Filters `paths` down to the ones `verify` approves, diagnosing each
    /// rejection through `onReject`. Per-path filtering (functional clause
    /// 3): approved paths pass through; rejected ones are dropped. Returns
    /// `nil` only when `paths` was non-empty and every path was rejected —
    /// the caller must then REFUSE the write, leaving the existing
    /// Keychain item and its ACL untouched (nonfunctional clause 6 — never
    /// leave an ACL naming zero trusted applications). An empty input
    /// returns `[]`, preserving today's system-default-ACL behaviour.
    public static func filter(
        _ paths: [String],
        verify: (String) -> Bool,
        onReject: (String, String) -> Void
    ) -> [String]? {
        guard !paths.isEmpty else { return [] }
        var approved: [String] = []
        for path in paths {
            if verify(path) {
                approved.append(path)
            } else {
                onReject(path, "code signature does not satisfy requirement \"\(policyRequirement)\"")
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
