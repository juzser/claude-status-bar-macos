import Foundation
import Security
import Testing
@testable import StatusBarCore

@Suite struct TrustedApplicationGateTests {
    // MARK: - Criterion 6: the policy — differential against two wrong verifiers
    //
    // Wrong verifier A: a bare `SecStaticCodeCheckValidity(code, [], nil)`,
    // which ACCEPTS ad-hoc signatures — `codesign --sign -` is free to
    // anyone who can write a candidate path, so SEC-1 reopens with one
    // extra step. Wrong verifier B: a check requiring an Apple/trusted
    // anchor or a Team Identifier, which REJECTS this repo's own
    // self-signed bundle (`TeamIdentifier=not set`) and breaks self-heal
    // for every build this repo produces. `anchor exists` is the specimen
    // that separates them: satisfied by any code with a certificate chain
    // (self-signed included), unsatisfied by ad-hoc code (no chain at all).

    @Test func policyRequirementIsExactlyAnchorExists() {
        #expect(TrustedApplicationGate.policyRequirement == "anchor exists")
    }

    /// Builds a signed copy of the test process's own executable under
    /// `FileManager.default.temporaryDirectory`, cleaned up afterwards.
    /// Never touches the real executable in place (nonfunctional clause 5).
    private func signedSpecimen(identity: String) throws -> URL {
        let source = URL(fileURLWithPath: CommandLine.arguments[0])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tag-specimens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("specimen")
        try FileManager.default.copyItem(at: source, to: copy)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", identity, copy.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return copy
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func defaultVerifyRejectsAdHocSignedCode() throws {
        let specimen = try signedSpecimen(identity: "-")
        defer { cleanup(specimen) }

        // Prove it really is ad-hoc.
        let dv = Process()
        dv.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        dv.arguments = ["-dv", specimen.path]
        let pipe = Pipe()
        dv.standardError = pipe
        try dv.run()
        dv.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(output.contains("Signature=adhoc"))

        #expect(TrustedApplicationGate.defaultVerify(specimen.path) == false)
    }

    /// Presence of the local signing identity is decided by exactly one
    /// pinned command (nonfunctional clause 4) — never `find-identity -v
    /// -p codesigning`, which filters by trust validity and reports this
    /// repo's self-signed leaf absent even when codesign is using it
    /// successfully.
    private func localSigningIdentityPresent() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-certificate", "-c", "ClaudeStatusBar Local Signing",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Keychains/login.keychain-db"),
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @Test func defaultVerifyAcceptsSelfSignedLocalIdentity() throws {
        guard localSigningIdentityPresent() else {
            // Recorded, not silently skipped: this criterion requires the
            // identity, which CI does not have.
            print("probe-c skipped: signing identity absent")
            return
        }
        let specimen = try signedSpecimen(identity: "ClaudeStatusBar Local Signing")
        defer { cleanup(specimen) }
        #expect(TrustedApplicationGate.defaultVerify(specimen.path) == true)
    }

    @Test func defaultVerifySanityApproveSystemBinaryRejectPlainFile() throws {
        #expect(TrustedApplicationGate.defaultVerify("/bin/ls") == true)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tag-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("not-code")
        try Data("not code".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plain.path)

        #expect(TrustedApplicationGate.defaultVerify(plain.path) == false)
    }

    /// Dev-run behaviour (criterion 7): an unsigned directory standing in
    /// for `.build/debug` under `swift run`/`swift test` is rejected too.
    @Test func defaultVerifyRejectsUnsignedDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tag-unsigned-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(TrustedApplicationGate.defaultVerify(dir.path) == false)
    }

    // MARK: - Criterion 8: the rejection is observable in the shipped app

    /// Probe (a): the sink actually writes, into a not-yet-existing
    /// subdirectory of the temp dir, exactly one line of exactly three
    /// tab-separated fields, field 2 equal to the path, field 3 equal to
    /// the reason.
    @Test func probeAWriteRejectionDiagnosticWritesOneThreeFieldLine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tag-diag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("sub/gate.log")

        let before = Date()
        TrustedApplicationGate.writeRejectionDiagnostic(path: "/bad/path", reason: "not signed", to: log)

        let contents = try String(contentsOf: log, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }
        #expect(lines.count == 1)
        let fields = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
        #expect(fields.count == 3)
        #expect(String(fields[1]) == "/bad/path")
        #expect(String(fields[2]) == "not signed")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        let parsed = formatter.date(from: String(fields[0])) ?? ISO8601DateFormatter().date(from: String(fields[0]))
        #expect(parsed != nil)
        if let parsed {
            #expect(abs(parsed.timeIntervalSince(before)) < 300)
        }
    }

    /// Second extension of probe (a): a destination whose parent directory
    /// cannot be created (a regular file occupies the path) must not throw
    /// or trap — the call returns normally and writes nothing — and a
    /// later good destination still writes, proving no latched failure.
    @Test func probeAWriteRejectionDiagnosticIsBestEffortAndDoesNotLatch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tag-blocked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocked = dir.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let unreachable = blocked.appendingPathComponent("sub/gate.log")

        // Must not throw/trap.
        TrustedApplicationGate.writeRejectionDiagnostic(path: "p", reason: "r", to: unreachable)
        #expect(FileManager.default.fileExists(atPath: unreachable.path) == false)

        let good = dir.appendingPathComponent("good/gate.log")
        TrustedApplicationGate.writeRejectionDiagnostic(path: "p2", reason: "r2", to: good)
        let contents = try String(contentsOf: good, encoding: .utf8)
        #expect(contents.contains("p2"))
    }

    /// Probe (c): the default sink goes somewhere a user can find.
    @Test func probeCDefaultDiagnosticLogURLIsUnderAppPathsRoot() {
        #expect(TrustedApplicationGate.defaultDiagnosticLogURL
                == AppPaths().root.appendingPathComponent("trusted-application-gate.log"))
    }

    /// Probe (e): the composition actually writes, exercised against a
    /// temporary URL — never `defaultOnReject`, never `AppPaths().root`.
    @Test func probeERejectionHandlerCompositionWrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tag-handler-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("sub/handler.log")

        let handler = TrustedApplicationGate.rejectionHandler(writingTo: log)
        handler("/x/path", "some reason")

        let contents = try String(contentsOf: log, encoding: .utf8)
        #expect(contents.contains("/x/path"))
        #expect(contents.contains("some reason"))
    }

    /// Probe (f): the default composition is textually `rejectionHandler
    /// (writingTo: defaultDiagnosticLogURL)`, not a closure literal.
    @Test func probeFDefaultOnRejectIsTheFactoryComposition() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../Sources/StatusBarCore/Accounts/TrustedApplicationGate.swift")
            .standardizedFileURL
        let text = try String(contentsOf: sourceURL, encoding: .utf8)
        let normalized = text
            .replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        #expect(normalized.contains(
            "defaultOnReject: (String, String) -> Void = rejectionHandler(writingTo: defaultDiagnosticLogURL)"))
        #expect(normalized.contains("defaultOnReject: (String, String) -> Void = {") == false)
    }

    /// Probe (h): no test may hold an executable reference to
    /// `TrustedApplicationGate.defaultOnReject` — a rejection under the
    /// default appends to the operator's real `AppPaths().root`. This
    /// scans every OTHER `.swift` file under `Tests/StatusBarCoreTests/`
    /// after stripping comments and string literals, and asserts the
    /// token occurs zero times as an executable reference. This file
    /// itself is excluded from the scan: it is the detector, and its own
    /// source necessarily spells the token out (in the needle constant and
    /// in doc comments describing it), which is not the hazard this probe
    /// guards against. Residual: a token count over stripped source,
    /// disclosed in the task result — it cannot see a reference reached
    /// through a stored alias, key path or reflection.
    @Test func probeHNoTestHoldsExecutableReferenceToDefaultOnReject() throws {
        let selfURL = URL(fileURLWithPath: #filePath)
        let testsDir = selfURL.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(
            at: testsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != selfURL.lastPathComponent }
        let needle = "TrustedApplicationGate.defaultOnReject"
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let stripped = text
                .replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #""(?:\\.|[^"\\])*""#, with: "\"\"", options: .regularExpression)
            #expect(stripped.contains(needle) == false,
                    "\(file.lastPathComponent) holds an executable reference to \(needle)")
        }
    }

    // MARK: - Criterion 3 / nonfunctional clause 3: no subprocess in defaultVerify

    /// Probe: `defaultVerify`'s own source contains none of the spawn
    /// tokens. Deny-by-default token scan over this one file, scoped to
    /// `Sources/` (tests are explicitly permitted to shell out to
    /// `codesign`/`security`). Residual: a textual blacklist, not a proof
    /// of subprocess-freedom — it cannot see a spawn reached through an
    /// API this list does not name.
    @Test func defaultVerifySourceContainsNoSpawnTokens() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../Sources/StatusBarCore/Accounts/TrustedApplicationGate.swift")
            .standardizedFileURL
        let text = try String(contentsOf: sourceURL, encoding: .utf8)
        let stripped = text
            .replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
        for token in ["Process(", "Process.init", "NSTask", "posix_spawn", "/usr/bin/codesign",
                      "/usr/bin/security", "system(", "URL(fileURLWithPath: \"/usr/bin\")"] {
            #expect(stripped.contains(token) == false, "found forbidden token \(token)")
        }
    }

    // MARK: - Filter semantics (functional clause 3)

    @Test func filterReturnsEmptyForEmptyInput() {
        let result = TrustedApplicationGate.filter([], verify: { _ in false }, onReject: { _, _ in
            Issue.record("onReject must not be called for empty input")
        })
        #expect(result == [])
    }

    @Test func filterReturnsNilWhenAllRejected() {
        var rejected: [String] = []
        let result = TrustedApplicationGate.filter(
            ["/a", "/b"], verify: { _ in false }, onReject: { path, _ in rejected.append(path) })
        #expect(result == nil)
        #expect(rejected == ["/a", "/b"])
    }

    @Test func filterKeepsOnlyApprovedPaths() {
        var rejected: [String] = []
        let result = TrustedApplicationGate.filter(
            ["/a", "/b"], verify: { $0 == "/a" }, onReject: { path, _ in rejected.append(path) })
        #expect(result == ["/a"])
        #expect(rejected == ["/b"])
    }
}
