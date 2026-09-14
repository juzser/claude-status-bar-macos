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
    // for every build this repo produces. `certificate leaf[subject.CN]
    // exists` is the specimen that separates them: satisfied by any code
    // whose leaf certificate has a subject (self-signed included),
    // unsatisfied by ad-hoc code (no certificate at all).
    //
    // Deviation, disclosed as a spec_change_request: the task brief pins
    // the literal `"anchor exists"`. That string is not valid Code
    // Requirement Language: `codesign -v -R="anchor exists" <path>`
    // reports "Requirement syntax error(s): line 1:1: unexpected token:
    // anchor" against both a self-signed and an ad-hoc specimen (verified
    // 2026-09-09), and `SecRequirementCreateWithString` returns
    // errSecCSInvalidRequirement (-67052) for it, so a verifier built on
    // it would reject every path unconditionally, including the
    // self-signed identity this same criterion requires it to accept.
    // `certificate leaf[subject.CN] exists` is the nearest valid
    // expression with the accept/reject behavior the brief describes.

    // MARK: - Criterion 1: structure and mapping

    @Test func claudeRequirementIsExactlyPinnedLiteralWithOUClause() {
        #expect(TrustedApplicationGate.claudeRequirement ==
                "anchor apple generic and identifier \"com.anthropic.claude-code\" and certificate leaf[subject.OU] = \"Q6L2SF6YDW\"")
    }

    @Test func selfCertificatePreconditionIsExactlyPinnedLiteral() {
        #expect(TrustedApplicationGate.selfCertificatePrecondition == "certificate leaf[subject.CN] exists")
    }

    @Test func classifyMapsAppEqualityWinsOverContent() {
        #expect(TrustedApplicationGate.classify("/tmp/A.app", appBundlePath: "/tmp/A.app") == .app)
        #expect(TrustedApplicationGate.classify("/tmp/x/claude", appBundlePath: "/tmp/A.app") == .claude)
        #expect(TrustedApplicationGate.classify("/bin/ls", appBundlePath: "/tmp/A.app") == nil)
        #expect(TrustedApplicationGate.classify("/tmp/x/claude", appBundlePath: "/tmp/x/claude") == .app)
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

    // MARK: - Criterion 2: the claude class rejects what the old policy admitted

    /// Copies the test's own executable to `<tmp>/<uuid>/claude` so it
    /// classifies `.claude`, signs it with `codesign`, and removes the
    /// parent directory in a defer (nonfunctional clause 5).
    private func claudeClassSpecimen(sign: (URL) throws -> Void) throws -> URL {
        let source = URL(fileURLWithPath: CommandLine.arguments[0])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-class-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("claude")
        try FileManager.default.copyItem(at: source, to: copy)
        try sign(copy)
        return copy
    }

    private func codesign(_ arguments: [String], path: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments + [path.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    /// (2a) The S2 probe: the shipped csb-audit-1 policy admitted this
    /// specimen (local identity, no OU pin); the per-path-class claude
    /// requirement must reject it.
    @Test func defaultVerifyRejectsLocalIdentitySignedClaudeSpecimen() throws {
        guard localSigningIdentityPresent() else {
            print("probe skipped: signing identity absent")
            return
        }
        let specimen = try claudeClassSpecimen { copy in
            try codesign(["--force", "--sign", "ClaudeStatusBar Local Signing", "-i", "com.anthropic.claude-code"], path: copy)
        }
        defer { cleanup(specimen) }
        #expect(TrustedApplicationGate.defaultVerify(specimen.path) == false)
    }

    /// (2b) Ad-hoc claude-class specimen: machine-independent, always rejected.
    @Test func defaultVerifyRejectsAdHocSignedClaudeSpecimen() throws {
        let specimen = try claudeClassSpecimen { copy in
            try codesign(["--force", "--sign", "-", "-i", "com.anthropic.claude-code"], path: copy)
        }
        defer { cleanup(specimen) }
        #expect(TrustedApplicationGate.defaultVerify(specimen.path) == false)
    }

    /// (2c) Apple-signed, wrong identifier: an unmodified copy of /bin/ls
    /// at `<tmp>/claude` (identifier com.apple.ls). `anchor apple generic`
    /// is true but the identifier clause is not, so the claude class
    /// rejects it too.
    @Test func defaultVerifyRejectsAppleSignedWrongIdentifierClaudeSpecimen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-class-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("claude")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: copy)
        #expect(TrustedApplicationGate.defaultVerify(copy.path) == false)
    }

    // MARK: - Criterion 3: the claude class admits the real binary

    /// For every claudeBinaryCandidates entry plus ~/.local/bin/claude
    /// (expanded here, never a gate literal): if it's an executable
    /// Developer-ID-signed claude, defaultVerify must approve it.
    @Test func defaultVerifyAcceptsRealClaudeBinaryIfPresent() throws {
        let homeDir = NSHomeDirectory()
        let candidates = LiveCredentialWriter.claudeBinaryCandidates
            + [(homeDir as NSString).appendingPathComponent(".local/bin/claude")]

        var qualifying: String?
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            let dv = Process()
            dv.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            dv.arguments = ["-dv", candidate]
            let pipe = Pipe()
            dv.standardError = pipe
            try dv.run()
            dv.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if output.contains("TeamIdentifier=Q6L2SF6YDW") {
                print("probe: \(candidate) codesign -dv: \(output)")
                qualifying = candidate
                break
            }
        }

        guard let qualifying else {
            print("probe skipped: no Developer ID claude binary")
            return
        }
        #expect(TrustedApplicationGate.defaultVerify(qualifying) == true)
    }

    @Test func defaultVerifySanityApproveClaudeClassRejectPlainFile() throws {
        // C5(5d): /bin/ls is now in NEITHER class (its last path component
        // is "ls", not "claude", and it is not this process's own bundle
        // path), so a bare Apple-signed system binary elsewhere on disk is
        // no longer admitted by any class.
        #expect(TrustedApplicationGate.defaultVerify("/bin/ls") == false)

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

    // MARK: - csb-signing-policy-1 C13: acquisition-error path, Bool reduction

    /// (P3) `acquireSelf` returning nil must yield `.noSelf`, never a
    /// force-unwrap crash and never a silent fall-through to
    /// `.candidateRejected`.
    @Test func c13p3NilSelfYieldsNoSelf() {
        let outcome = TrustedApplicationGate.defaultOutcome(
            "/tmp/anything", appBundlePath: "/tmp/anything", acquireSelf: { nil })
        #expect(outcome == .noSelf)
    }

    /// (P3, structural) The gate guards every acquisition call on
    /// `errSecSuccess` and force-unwraps none of them.
    @Test func c13p3AcquisitionCallsAreGuardedNotForceUnwrapped() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../Sources/StatusBarCore/Accounts/TrustedApplicationGate.swift")
            .standardizedFileURL
        let text = try String(contentsOf: sourceURL, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        let guardedCalls = ["SecCodeCopyStaticCode", "SecStaticCodeCheckValidity", "SecCodeCopyDesignatedRequirement"]
        for (index, line) in lines.enumerated() {
            for call in guardedCalls where line.contains("\(call)(") {
                let lineNumber = index + 1
                let window = lines[index..<min(index + 2, lines.count)].joined(separator: "\n")
                #expect(window.contains("errSecSuccess"),
                        "SecCodeCopyStaticCode result used without an errSecSuccess guard at TrustedApplicationGate.swift:\(lineNumber)")
                #expect(!line.hasSuffix("!"),
                        "\(call) force-unwrapped at TrustedApplicationGate.swift:\(lineNumber)")
            }
        }
    }

    /// (P4) The Bool entry point can never drift from the outcome: for
    /// self, an ad-hoc app-class specimen and a non-classified path,
    /// `defaultVerify` is exactly `defaultOutcome(...) == .approved`.
    @Test func c13p4DefaultVerifyIsExactlyTheOutcomeReduction() throws {
        var selfCode: SecCode?
        let selfStatus = SecCodeCopySelf([], &selfCode)
        var selfURLRef: CFURL?
        if selfStatus == errSecSuccess, let selfCode {
            var staticCode: SecStaticCode?
            if SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode {
                SecCodeCopyPath(staticCode, [], &selfURLRef)
            }
        }
        var probePaths: [String] = ["/bin/ls"]
        if let selfURLRef {
            probePaths.append((selfURLRef as URL).path)
        }

        let s4 = try appClassSpecimen(sign: "-", identifier: "com.juzser.ClaudeStatusBar")
        defer { cleanup(s4) }
        probePaths.append(s4.path)

        for p in probePaths {
            let expected = TrustedApplicationGate.defaultOutcome(p, appBundlePath: Bundle.main.bundlePath) == .approved
            #expect(TrustedApplicationGate.defaultVerify(p) == expected,
                    "defaultVerify(\(p)) diverges from defaultOutcome reduction")
        }
    }

    // MARK: - csb-signing-policy-1 C4/C5: the app class, identity-signed specimens

    /// Builds an app-class specimen: a signed copy of the test's own
    /// executable, under `FileManager.default.temporaryDirectory`, removed
    /// by the caller's `cleanup(_:)` (nonfunctional clause 5).
    private func appClassSpecimen(sign identity: String, identifier: String) throws -> URL {
        let source = URL(fileURLWithPath: CommandLine.arguments[0])
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-class-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("specimen")
        try FileManager.default.copyItem(at: source, to: copy)
        try codesign(["--force", "--sign", identity, "-i", identifier], path: copy)
        return copy
    }

    private func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        return status == errSecSuccess ? code : nil
    }

    /// (4a)-(4d), (5a): S1/S2 = local-identity-signed, identifier
    /// `com.juzser.ClaudeStatusBar`; S3 = local-identity-signed, a
    /// different identifier; S4 = ad-hoc WITH S1's identifier (deliberate:
    /// proves the self DR is not identifier-only, csb-signing-policy-1
    /// plan-quorum critique #29).
    @Test func c4And5AppClassIdentitySignedCases() throws {
        guard localSigningIdentityPresent() else {
            print("probe skipped: signing identity absent")
            return
        }
        let s1 = try appClassSpecimen(sign: "ClaudeStatusBar Local Signing", identifier: "com.juzser.ClaudeStatusBar")
        defer { cleanup(s1) }
        let s2 = try appClassSpecimen(sign: "ClaudeStatusBar Local Signing", identifier: "com.juzser.ClaudeStatusBar")
        defer { cleanup(s2) }
        let s3 = try appClassSpecimen(sign: "ClaudeStatusBar Local Signing", identifier: "com.other")
        defer { cleanup(s3) }
        let s4 = try appClassSpecimen(sign: "-", identifier: "com.juzser.ClaudeStatusBar")
        defer { cleanup(s4) }

        guard let s1Code = staticCode(at: s1), let s4Code = staticCode(at: s4) else {
            Issue.record("could not acquire SecStaticCode for S1/S4")
            return
        }

        // (4a) app class admits a self-signed sibling.
        #expect(TrustedApplicationGate.verify(s2.path, appBundlePath: s2.path, selfCode: s1Code) == true)
        // (4b) ad-hoc candidate, identity-signed self carrying the SAME
        // identifier: rejected — the self DR is not identifier-only.
        #expect(TrustedApplicationGate.verify(s4.path, appBundlePath: s4.path, selfCode: s1Code) == false)
        // (4c) identity-signed candidate under a DIFFERENT identifier: the
        // self DR pins the identifier, so this is rejected too.
        #expect(TrustedApplicationGate.verify(s3.path, appBundlePath: s3.path, selfCode: s1Code) == false)
        // (4d) ad-hoc self: step (ii)'s fail-safe admits nothing, not even
        // byte-identical ad-hoc code.
        #expect(TrustedApplicationGate.verify(s4.path, appBundlePath: s4.path, selfCode: s4Code) == false)

        // (5a) S2 relocated to a basename other than "claude", verified
        // against a DIFFERENT appBundlePath (S1): the relocated path is
        // neither equal to appBundlePath nor named "claude", so it falls
        // in NEITHER class and is rejected outright — proving requirements
        // are not tried against every path regardless of classification.
        let renamed = s2.deletingLastPathComponent().appendingPathComponent("not-claude")
        try FileManager.default.moveItem(at: s2, to: renamed)
        #expect(TrustedApplicationGate.verify(renamed.path, appBundlePath: s1.path, selfCode: s1Code) == false)
    }

    /// (5b) An unsigned directory in the app class, with `selfCode: nil`.
    @Test func c5bUnsignedDirectoryAppClassWithNilSelfIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("c5b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let appDir = dir.appendingPathComponent("A.app", isDirectory: true)
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        #expect(TrustedApplicationGate.verify(appDir.path, appBundlePath: appDir.path, selfCode: nil) == false)
    }

    /// (4e) `scripts/make-app.sh` never sets a custom designated
    /// requirement — the app class relies on codesign's DEFAULT DR.
    @Test func c4eMakeAppScriptSetsNoCustomDesignatedRequirement() throws {
        let scriptURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../scripts/make-app.sh")
            .standardizedFileURL
        let text = try String(contentsOf: scriptURL, encoding: .utf8)
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            guard line.contains("codesign") else { continue }
            let tokens = line.split(separator: " ").map(String.init)
            #expect(!tokens.contains("-r") && !tokens.contains("--requirements"),
                    "make-app.sh:\(index + 1) sets a custom designated requirement; the app class relies on the default DR")
        }
    }

    // MARK: - csb-signing-policy-1 C11/C12: the app class, wired end-to-end

    /// Measures the running test process's own signature (never assumed)
    /// and records it; used by both P1 (C11) and to decide P2's (C12) skip
    /// branch.
    private func measureSelf() throws -> (path: String, output: String, hasCertificate: Bool) {
        var selfCode: SecCode?
        #expect(SecCodeCopySelf([], &selfCode) == errSecSuccess)
        var staticCode: SecStaticCode?
        #expect(SecCodeCopyStaticCode(selfCode!, [], &staticCode) == errSecSuccess)
        var pathRef: CFURL?
        #expect(SecCodeCopyPath(staticCode!, [], &pathRef) == errSecSuccess)
        let path = (pathRef! as URL).path

        func run(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        let dv = try run(["-dv", path])
        let dr = try run(["-d", "-r-", path])
        let output = "path=\(path)\n\(dv)\ndesignated requirement:\n\(dr)"

        // Measured, not assumed: "certificate leaf[subject.CN] exists" is
        // the SAME precondition `appClassOutcome` applies to self, checked
        // here with the same Security-framework call so the measurement
        // cannot drift from what the gate itself decides. A codesign -dv
        // text heuristic (presence of "Authority=") is not reliable for
        // every code-signing shape (observed 2026-09-14: an Apple-signed
        // CommandLineTools helper with no "Authority=" line whose
        // SecStaticCodeCheckValidity against this precondition still
        // succeeds).
        var precondition: SecRequirement?
        let preconditionStatus = SecRequirementCreateWithString(
            TrustedApplicationGate.selfCertificatePrecondition as CFString, [], &precondition)
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        let hasCertificate = preconditionStatus == errSecSuccess && precondition != nil
            && SecStaticCodeCheckValidity(staticCode!, flags, precondition) == errSecSuccess
        return (path, output, hasCertificate)
    }

    /// (P1) `defaultOutcome(selfPath, appBundlePath: selfPath)` matches the
    /// measured self exactly: `.approved` when self carries a certificate,
    /// `.selfFailsPrecondition` otherwise. Graded whichever way the
    /// measurement falls (spec-review r3).
    @Test func c11p1DefaultOutcomeOnSelfMatchesMeasurement() throws {
        let measurement = try measureSelf()
        print("C11 self measurement:\n\(measurement.output)")
        let outcome = TrustedApplicationGate.defaultOutcome(measurement.path, appBundlePath: measurement.path)
        if measurement.hasCertificate {
            print("P1 branch: approved")
            #expect(outcome == .approved)
        } else {
            print("P1 branch: selfFailsPrecondition")
            #expect(outcome == .selfFailsPrecondition)
        }
    }

    /// (P2) The self/candidate swap: an ad-hoc S4 read as SELF must fail
    /// the precondition, not be treated as the candidate. Caught only by
    /// an ad-hoc specimen — an identity-signed one clears the precondition
    /// under either ordering and is blind to this mis-wiring.
    @Test func c12p2SelfCandidateSwapCaughtByAdHocSpecimen() throws {
        let measurement = try measureSelf()
        guard measurement.hasCertificate else {
            print("probe skipped: self is ad-hoc, swap unobservable")
            return
        }
        let s4 = try appClassSpecimen(sign: "-", identifier: "com.juzser.ClaudeStatusBar")
        defer { cleanup(s4) }
        let outcome = TrustedApplicationGate.defaultOutcome(s4.path, appBundlePath: s4.path)
        #expect(outcome == .candidateRejected)
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
    /// default appends to the operator's real `AppPaths().root`. Retro-fit
    /// (round B) to the corrected step (2b): this scans every OTHER
    /// `.swift` file under `Tests/StatusBarCoreTests/` (excluding the
    /// fixtures directory, whose specimens are never-compiled match data
    /// graded separately) via `ProbeHCheck`, which runs the pinned
    /// `SourceTextMatcher` procedure including the v13 interpolation-
    /// retention correction, and asserts the token occurs zero times as an
    /// executable reference. This file itself is excluded from the scan:
    /// it is the detector, and its own source necessarily spells the token
    /// out (in the needle constant and in doc comments describing it),
    /// which is not the hazard this probe guards against. Residual: a
    /// token count over stripped source, disclosed in the task result —
    /// it cannot see a reference reached through a stored alias, key path
    /// or reflection.
    @Test func probeHNoTestHoldsExecutableReferenceToDefaultOnReject() throws {
        let selfURL = URL(fileURLWithPath: #filePath)
        let testsDir = selfURL.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(
            at: testsDir, includingPropertiesForKeys: nil)
            .filter {
                $0.pathExtension == "swift" && $0.lastPathComponent != selfURL.lastPathComponent
            }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let (refs, unresolved) = ProbeHCheck.executableReferences(text)
            #expect(unresolved.isEmpty, "\(file.lastPathComponent): unresolved subprocess/interpolation site(s)")
            #expect(refs.isEmpty,
                    "\(file.lastPathComponent) holds \(refs.count) executable reference(s) to TrustedApplicationGate.defaultOnReject at line(s) \(refs.map(\.line))")
        }
    }

    /// Repo-relative `Sources/StatusBarCore/Accounts/` directory, resolved
    /// from `#filePath` the same way probe (f) and the spawn-token probe
    /// already do.
    private var sourcesAccountsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../Sources/StatusBarCore/Accounts")
            .standardizedFileURL
    }

    /// Probes (b) and (g) share this shape: isolate the sink's parameter
    /// list, assert the pinned default appears there exactly once, and
    /// assert the member occurs exactly once in the whole comment/literal-
    /// stripped file (excluding a dead reference elsewhere). Criterion 8's
    /// v13 correction: this is a DOUBLE COUNT against three verdict texts,
    /// not a single assertion against C_post alone -- C_post == 1 with
    /// C_pre > C_post is a disclosed NOTE, not a failure, and it must be
    /// reachable, not merely asserted away.
    private func assertDefaultParameter(
        marker: String, defaultText: String, member: String, file: String
    ) throws {
        let text = try String(contentsOf: sourcesAccountsDir.appendingPathComponent(file), encoding: .utf8)
        let procedure = SourceTextMatcher.run(text)
        guard let slice = SourceTextMatcher.declarationSlice(startingAt: marker, in: procedure.postLiteralStripNormalized) else {
            Issue.record("\(file): could not isolate \(marker) declaration slice")
            return
        }
        #expect(SourceTextMatcher.occurrenceCount(of: defaultText, in: slice) == 1,
                "\(file): expected \(defaultText) exactly once in \(marker) parameter list")

        let cPost = SourceTextMatcher.occurrenceCount(of: member, in: procedure.postLiteralStripNormalized)
        let cPre = SourceTextMatcher.occurrenceCount(of: member, in: procedure.preLiteralStripNormalized)

        if cPost != 1 {
            let sites = SourceTextMatcher.occurrences(of: member, in: procedure.literalStrippedWithNewlines)
                .map { "\(file):\($0.line)" }.joined(separator: ", ")
            let message = "Expectation failed: \(member) occurs \(cPost) times as an executable reference in Sources/ (\(sites) each), expected exactly 1"
            Issue.record("\(message)")
            return
        }

        if cPre > cPost {
            let postCounts = SourceTextMatcher.occurrenceLineCounts(of: member, in: procedure.literalStrippedWithNewlines)
            let preCounts = SourceTextMatcher.occurrenceLineCounts(of: member, in: procedure.commentStrippedWithNewlines)
            let literalOnlySites = preCounts.keys.sorted().compactMap { line -> String? in
                let extra = preCounts[line, default: 0] - postCounts[line, default: 0]
                return extra > 0 ? "\(file):\(line)" : nil
            }.joined(separator: ", ")
            let note = "note: \(member) also occurs \(cPre - cPost) time(s) inside a string literal in Sources/ (\(literalOnlySites)): inert match data, not counted, not a failure"
            // Disclosed, not failed: this is the note the v13 correction
            // makes reachable, and it must never fail the probe.
            print(note)
            return
        }

        // PASS: silence is the verdict text, per criterion 8's v13 correction.
        _ = "ok: \(member) occurs exactly 1 time as an executable reference in Sources/"
    }

    /// Probe (b): the default is `TrustedApplicationGate.defaultOnReject`,
    /// at both call sites.
    @Test func probeBOnRejectDefaultsToProductionSinkAtBothSites() throws {
        try assertDefaultParameter(
            marker: "static func performWrite(",
            defaultText: "onReject: (String, String) -> Void = TrustedApplicationGate.defaultOnReject",
            member: "TrustedApplicationGate.defaultOnReject",
            file: "LiveCredentialWriter.swift")
        try assertDefaultParameter(
            marker: "static func performRepairWrite(",
            defaultText: "onReject: (String, String) -> Void = TrustedApplicationGate.defaultOnReject",
            member: "TrustedApplicationGate.defaultOnReject",
            file: "AccountCredentialVault.swift")
    }

    /// Probe (g): the verifier default is `TrustedApplicationGate.defaultVerify`,
    /// at both call sites — the parameter that decides whether SEC-1 is
    /// actually closed, since the production callers never pass `verify:`
    /// explicitly.
    @Test func probeGVerifyDefaultsToProductionGateAtBothSites() throws {
        try assertDefaultParameter(
            marker: "static func performWrite(",
            defaultText: "verify: (String) -> Bool = TrustedApplicationGate.defaultVerify",
            member: "TrustedApplicationGate.defaultVerify",
            file: "LiveCredentialWriter.swift")
        try assertDefaultParameter(
            marker: "static func performRepairWrite(",
            defaultText: "verify: (String) -> Bool = TrustedApplicationGate.defaultVerify",
            member: "TrustedApplicationGate.defaultVerify",
            file: "AccountCredentialVault.swift")
    }

    /// Probe (d): wired at both sites — with an explicit recorder, a
    /// rejected path records a line containing the rejected path and the
    /// reason, at site 1 (`performWrite`) and site 2 (`performRepairWrite`).
    @Test func probeDBothSitesRecordRejectedPathAndReason() {
        var site1: [(path: String, reason: String)] = []
        let ok1 = LiveCredentialWriter.performWrite(
            data: Data("token".utf8),
            trustedPaths: ["/tmp/rejected-site-1"],
            service: LiveCredentialWriter.service,
            account: "ser",
            verify: { _ in false },
            onReject: { path, reason in site1.append((path, reason)) },
            update: { _, _ in errSecSuccess },
            add: { _, _ in errSecSuccess }
        )
        #expect(ok1 == false)
        #expect(site1.count == 1)
        #expect(site1.first?.path == "/tmp/rejected-site-1")
        #expect(site1.first?.reason.isEmpty == false)

        var site2: [(path: String, reason: String)] = []
        let ok2 = AccountCredentialVault.performRepairWrite(
            data: Data("token".utf8),
            service: AccountCredentialVault.service,
            accountId: "ser",
            trustedPaths: ["/tmp/rejected-site-2"],
            verify: { _ in false },
            onReject: { path, reason in site2.append((path, reason)) },
            add: { _, _ in errSecSuccess },
            update: { _, _ in errSecSuccess }
        )
        #expect(ok2 == false)
        #expect(site2.count == 1)
        #expect(site2.first?.path == "/tmp/rejected-site-2")
        #expect(site2.first?.reason.isEmpty == false)
    }

    // MARK: - Criterion 9: the test-side security inventory, over the real tree

    /// `SecurityInventoryCheck`, wired to the real `Tests/StatusBarCoreTests/`
    /// tree rather than a fixture specimen — every `.swift` file except the
    /// never-compiled `Fixtures/static-assertions/**` specimens themselves
    /// (which are match data, not code the inventory scans) must pass.
    @Test func realTestTreeSecurityInventoryHasNoMutatingSubcommand() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fixturesDir = testsDir.appendingPathComponent("Fixtures/static-assertions").standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: testsDir, includingPropertiesForKeys: nil) else {
            Issue.record("could not enumerate \(testsDir.path)")
            return
        }
        for case let file as URL in enumerator {
            guard file.pathExtension == "swift" else { continue }
            guard !file.standardizedFileURL.path.hasPrefix(fixturesDir.path) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let verdict = SecurityInventoryCheck.check(text)
            #expect(verdict == nil, "\(file.lastPathComponent): \(verdict ?? "")")
        }
    }

    // MARK: - Criterion 12: the paired CI signing step, over the real workflow file

    /// `CISigningStepCheck`, wired to the real `.github/workflows/ci.yml`
    /// (read-only; the file is not in this task's claims).
    @Test func realCiWorkflowHasPairedSigningArgvTestStep() throws {
        let ciYML = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../.github/workflows/ci.yml")
            .standardizedFileURL
        let text = try String(contentsOf: ciYML, encoding: .utf8)
        #expect(CISigningStepCheck.check(text) == true)
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

    /// (6a-i, 6a-ii) THE (e-3) CLOSURE RUNS OVER THE REAL FILE. Armed, not
    /// silent: first asserts `defaultVerify` is actually declared as a
    /// `func` (else `transitiveOutOfFileSymbol` returns nil vacuously),
    /// then runs the closure and asserts it reaches the members a
    /// spelling-blind walk could otherwise miss.
    @Test func defaultVerifyClosureStaysInFile() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../Sources/StatusBarCore/Accounts/TrustedApplicationGate.swift")
            .standardizedFileURL
        let text = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(text.range(of: #"(?:static\s+)?func\s+defaultVerify\s*\("#, options: .regularExpression) != nil,
                "defaultVerify is not declared as a func in TrustedApplicationGate.swift")
        let reached = DefaultVerifySpawnCheck.reached(text)
        #expect(reached.isSuperset(of: ["defaultOutcome", "copySelfStaticCode"]),
                "closure from defaultVerify does not reach: \(Set(["defaultOutcome", "copySelfStaticCode"]).subtracting(reached))")
        let verdict = DefaultVerifySpawnCheck.check(text, label: "TrustedApplicationGate.swift")
        #expect(verdict == nil, Comment(rawValue: verdict ?? ""))
    }

    /// (6a-iii) THE WALK'S TREATMENT OF PARAMETER NAMES, DOTTED CALLEES AND
    /// DEFAULT-ARGUMENT VALUES, pinned with inline-string regressions
    /// (Swift source in string literals, never compiled).
    @Test func spawnCheckWalkRules() {
        // (alpha) an undotted callee that is a parameter name of the
        // function being walked is admitted and not followed.
        let alphaCompliant = """
        func defaultVerify(_ path: String) -> Bool {
            return defaultOutcome(path)
        }
        func defaultOutcome(_ path: String, acquireSelf: () -> SecStaticCode? = copySelfStaticCode) -> Bool {
            return acquireSelf() != nil
        }
        func copySelfStaticCode() -> SecStaticCode? {
            return nil
        }
        """
        #expect(DefaultVerifySpawnCheck.check(alphaCompliant, label: "alpha") == nil)

        // (gamma) a bare identifier used as a default-argument value is
        // enqueued exactly like a called identifier, even though nothing
        // calls it by name -- graded even when `copySelfStaticCode` is NOT
        // declared in-text.
        let gammaUndeclared = """
        func defaultVerify(_ path: String) -> Bool {
            return defaultOutcome(path)
        }
        func defaultOutcome(_ path: String, acquireSelf: () -> SecStaticCode? = copySelfStaticCode) -> Bool {
            return acquireSelf() != nil
        }
        """
        let gammaVerdict = DefaultVerifySpawnCheck.check(gammaUndeclared, label: "gamma")
        #expect(gammaVerdict?.contains("defaultVerify -> defaultOutcome -> copySelfStaticCode") == true)

        // (beta) deny-by-default dotted callee: a non-`self`/`Self`/
        // `TrustedApplicationGate` receiver whose last segment is not
        // allowlisted is flagged with the full dotted name.
        let betaFlagged = """
        func defaultVerify(_ p: SomeType) -> Bool {
            return p.spawnHelper()
        }
        """
        let betaVerdict = DefaultVerifySpawnCheck.check(betaFlagged, label: "beta-flagged")
        #expect(betaVerdict?.contains("defaultVerify -> p.spawnHelper") == true)

        // (beta) `Self.`-prefixed callee resolves through its second
        // segment under the normal declared-in-file rule.
        let betaSelfDeclared = """
        func defaultVerify(_ path: String) -> Bool {
            return Self.helper()
        }
        func helper() -> Bool {
            return true
        }
        """
        #expect(DefaultVerifySpawnCheck.check(betaSelfDeclared, label: "beta-self") == nil)

        // (beta) a dotted callee whose last segment IS allowlisted is
        // admitted rather than flagged.
        let betaAllowlisted = """
        func defaultVerify(_ path: String) -> Bool {
            return path.hasSuffix("claude") && FileManager.default.fileExists(atPath: path)
        }
        """
        #expect(DefaultVerifySpawnCheck.check(betaAllowlisted, label: "beta-allowlisted") == nil)
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

    /// (6c) The rejection reason no longer interpolates the deleted
    /// `policyRequirement`: it names the per-path class (or "no path
    /// class") and says nothing else about the file (N6).
    @Test func filterRejectionReasonNamesPerPathClassNotAPolicyString() {
        var reasons: [String] = []
        _ = TrustedApplicationGate.filter(
            ["/tmp/x/claude"], verify: { _ in false }, onReject: { _, reason in reasons.append(reason) },
            appBundlePath: "/tmp/A.app")
        #expect(reasons.first?.contains("per-path-class") == true)
    }
}

// MARK: - Criterion 8: THE PINNED SOURCE-TEXT MATCH PROCEDURE
//
// Shared by every textual probe this task's acceptance criteria describe
// (probes b, f, g, h; criterion 9's inventory; criterion 12's YAML pair;
// criterion 6 probe (e)). Round A builds this procedure once, correctly,
// plus the sixteen static-assertions fixtures and enough of a matcher
// entry point to grade each one. Wiring probes (b)/(d)/(g) into the real
// Sources/ assertions and retro-fitting probe (h) to call this corrected
// procedure are round B's job, not round A's.
enum SourceTextMatcher {
    /// One site where an interpolation segment inside a string literal
    /// could not be delimited (unbalanced parens, or nesting this matcher
    /// does not implement). UNRESOLVED IS A FAILURE, NOT A NON-MATCH: the
    /// caller must surface it, never silently drop the site.
    struct Unresolved {
        let line: Int
        let snippet: String
    }

    struct Procedure {
        /// After step (2) comment/dead-code strip and step (3) whitespace
        /// normalisation -- string literals intact. Basis for C_pre.
        let preLiteralStripNormalized: String
        /// (2) output, original newlines preserved, so a caller can report
        /// which line a literal-only occurrence falls on for C_pre.
        let commentStrippedWithNewlines: String
        /// After step (2), step (2b) string-literal strip (interpolation
        /// segments RETAINED, per the v13 correction) and step (3). Basis
        /// for C_post -- the count this task's probes actually bind.
        let postLiteralStripNormalized: String
        /// (2)+(2b) output, original newlines preserved, so a caller can
        /// report which line an occurrence falls on.
        let literalStrippedWithNewlines: String
        let unresolved: [Unresolved]
    }

    static func run(_ sourceText: String) -> Procedure {
        let commentStripped = stripCommentsAndDeadCode(sourceText)
        let (literalStripped, unresolved) = stripStringLiterals(commentStripped)
        return Procedure(
            preLiteralStripNormalized: normalizeWhitespace(commentStripped),
            commentStrippedWithNewlines: commentStripped,
            postLiteralStripNormalized: normalizeWhitespace(literalStripped),
            literalStrippedWithNewlines: literalStripped,
            unresolved: unresolved)
    }

    /// Per-line occurrence counts of `needle` in `text`, for diffing C_pre
    /// against C_post line-by-line to locate a literal-only occurrence.
    static func occurrenceLineCounts(of needle: String, in text: String) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for occurrence in occurrences(of: needle, in: text) {
            counts[occurrence.line, default: 0] += 1
        }
        return counts
    }

    static func occurrenceCount(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return count
    }

    /// Isolates a function declaration's parameter-list slice: scans
    /// forward from the end of `marker` (which must end in `(`) with a
    /// parenthesis-depth counter to the matching close paren. Used by
    /// probes (b) and (g), which must locate a default value inside the
    /// surrounding declaration rather than matching the whole file.
    static func declarationSlice(startingAt marker: String, in text: String) -> String? {
        guard let start = text.range(of: marker) else { return nil }
        var depth = 0
        var i = start.upperBound
        while i < text.endIndex {
            if text[i] == "(" { depth += 1 }
            if text[i] == ")" {
                if depth == 0 { return String(text[start.lowerBound..<text.index(after: i)]) }
                depth -= 1
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// Every occurrence of `needle`, each with the 1-based line it starts
    /// on and that line's trimmed text, for a diagnostic that names sites.
    static func occurrences(of needle: String, in text: String) -> [(line: Int, snippet: String)] {
        var results: [(Int, String)] = []
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: needle, range: range) {
            let line = text[..<found.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            let lineStart = text[..<found.lowerBound].lastIndex(of: "\n").map(text.index(after:)) ?? text.startIndex
            let lineEnd = text[found.lowerBound...].firstIndex(of: "\n") ?? text.endIndex
            results.append((line, String(text[lineStart..<lineEnd]).trimmingCharacters(in: .whitespaces)))
            range = found.upperBound..<text.endIndex
        }
        return results
    }

    // MARK: Step (2): strip comments and dead code, preserving strings.

    private static func stripCommentsAndDeadCode(_ text: String) -> String {
        let chars = Array(text)
        var result = ""
        result.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            if let span = literalSpan(chars, at: i) {
                result += String(chars[span.start..<span.end])
                i = span.end
                continue
            }
            if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "*" {
                var depth = 1
                i += 2
                while i < chars.count, depth > 0 {
                    if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "*" { depth += 1; i += 2 }
                    else if i + 1 < chars.count, chars[i] == "*", chars[i + 1] == "/" { depth -= 1; i += 2 }
                    else { i += 1 }
                }
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return stripDeadIfFalse(result)
    }

    private static func stripDeadIfFalse(_ text: String) -> String {
        var out: [Substring] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !skipping, trimmed.hasPrefix("#if false") { skipping = true; continue }
            if skipping, trimmed.hasPrefix("#endif") { skipping = false; continue }
            if skipping { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    // MARK: Step (2b): strip string literals, retaining interpolation segments.

    private static func stripStringLiterals(_ text: String) -> (String, [Unresolved]) {
        let chars = Array(text)
        var result = ""
        var unresolved: [Unresolved] = []
        var i = 0
        while i < chars.count {
            if let span = literalSpan(chars, at: i) {
                let (segments, unresolvedSnippet) = interpolationSegments(chars, span: span)
                if let unresolvedSnippet {
                    let line = String(chars[..<span.start]).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                    unresolved.append(Unresolved(line: line, snippet: unresolvedSnippet))
                    result += " "
                } else {
                    result += " " + segments.joined(separator: " ") + " "
                }
                i = span.end
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return (result, unresolved)
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Literal boundary + interpolation scanning shared by (2) and (2b)

    private struct LiteralSpan {
        let start: Int
        let end: Int
        let bodyStart: Int
        let bodyEnd: Int
        let lead: [Character]
    }

    private static func literalSpan(_ chars: [Character], at i: Int) -> LiteralSpan? {
        var hashCount = 0
        var j = i
        while j < chars.count, chars[j] == "#" { hashCount += 1; j += 1 }
        guard j < chars.count, chars[j] == "\"" else { return nil }
        let lead = Array("\\" + String(repeating: "#", count: hashCount) + "(")
        if j + 2 < chars.count, chars[j + 1] == "\"", chars[j + 2] == "\"" {
            let bodyStart = j + 3
            var k = bodyStart
            while k + 2 < chars.count {
                if chars[k] == "\"", chars[k + 1] == "\"", chars[k + 2] == "\"" {
                    var h = 0
                    var m = k + 3
                    while h < hashCount, m < chars.count, chars[m] == "#" { h += 1; m += 1 }
                    if h == hashCount {
                        return LiteralSpan(start: i, end: m, bodyStart: bodyStart, bodyEnd: k, lead: lead)
                    }
                }
                k += 1
            }
            return LiteralSpan(start: i, end: chars.count, bodyStart: bodyStart, bodyEnd: chars.count, lead: lead)
        }
        let bodyStart = j + 1
        var k = bodyStart
        while k < chars.count {
            if chars[k] == "\\" { k += 2; continue }
            if chars[k] == "\"" {
                var h = 0
                var m = k + 1
                while h < hashCount, m < chars.count, chars[m] == "#" { h += 1; m += 1 }
                if h == hashCount {
                    return LiteralSpan(start: i, end: m, bodyStart: bodyStart, bodyEnd: k, lead: lead)
                }
            }
            if chars[k] == "\n", hashCount == 0 { break }
            k += 1
        }
        return LiteralSpan(start: i, end: k, bodyStart: bodyStart, bodyEnd: k, lead: lead)
    }

    private static func interpolationSegments(_ chars: [Character], span: LiteralSpan) -> ([String], String?) {
        var segments: [String] = []
        var k = span.bodyStart
        while k < span.bodyEnd {
            if chars[k] == "\\" {
                if leadMatches(chars, at: k, lead: span.lead) {
                    let interpStart = k + span.lead.count
                    var depth = 1
                    var m = interpStart
                    while m < span.bodyEnd, depth > 0 {
                        if chars[m] == "(" { depth += 1; m += 1; continue }
                        if chars[m] == ")" { depth -= 1; m += 1; continue }
                        if chars[m] == "\"" || chars[m] == "#", let nested = literalSpan(chars, at: m), nested.start == m {
                            m = nested.end
                            continue
                        }
                        m += 1
                    }
                    if depth == 0 {
                        segments.append(String(chars[interpStart..<(m - 1)]))
                        k = m
                        continue
                    }
                    return (segments, String(chars[span.start..<span.bodyEnd]))
                }
                k += 2
                continue
            }
            k += 1
        }
        return (segments, nil)
    }

    private static func leadMatches(_ chars: [Character], at i: Int, lead: [Character]) -> Bool {
        guard i + lead.count <= chars.count else { return false }
        return Array(chars[i..<(i + lead.count)]) == lead
    }
}

/// A fixture-scoped grading entry point for probe (h): executable
/// references to the production default outside any string literal.
/// The real probe (`probeHNoTestHoldsExecutableReferenceToDefaultOnReject`)
/// is retro-fitted to call the corrected `SourceTextMatcher` in round B;
/// this type exists only so round A's sixteen fixtures can be graded.
enum ProbeHCheck {
    static func executableReferences(_ sourceText: String) -> (refs: [(line: Int, snippet: String)], unresolved: [SourceTextMatcher.Unresolved]) {
        let procedure = SourceTextMatcher.run(sourceText)
        let refs = SourceTextMatcher.occurrences(of: "TrustedApplicationGate.defaultOnReject", in: procedure.literalStrippedWithNewlines)
        return (refs, procedure.unresolved)
    }
}

// MARK: - Criterion 9: the test-side security inventory, scoped to a
// standalone fixture specimen. Wiring this over the real Tests/ tree is
// round B.
enum SecurityInventoryCheck {
    static let readOnlySubcommands: Set<String> = ["find-certificate", "find-identity", "dump-keychain"]

    static func check(_ sourceText: String) -> String? {
        guard hasProcessConfig(sourceText) else { return nil }
        guard let cfg = subprocessConfig(sourceText) else {
            return "test-side security inventory cannot resolve the subprocess configuration: this task requires literal, statically-checkable executable paths and subcommands in tests; an assembled invocation is a spec-change-request, not a passing diff"
        }
        guard cfg.executable.hasSuffix("/security") || cfg.executable == "security" else { return nil }
        guard let subcommand = cfg.firstArgument else {
            return "test-side security inventory cannot resolve the subprocess configuration: this task requires literal, statically-checkable executable paths and subcommands in tests; an assembled invocation is a spec-change-request, not a passing diff"
        }
        if readOnlySubcommands.contains(subcommand), !cfg.arguments.contains("-d") {
            return nil
        }
        return "test invokes security with the subcommand \"\(subcommand)\": nonfunctional clause 4 forbids every mutating security subcommand on every keychain including a temporary one, and that command is the SEC-2 bug this epic exists to fix"
    }

    private struct Config {
        let executable: String
        let firstArgument: String?
        let arguments: [String]
    }

    /// Real-tree correction (round B): a plain `contains("Process(")` false
    /// -positives on identifiers that merely end in "Process(", such as a
    /// test function named `...LongRunningProcess()`. Require a
    /// non-identifier character (or start of text) immediately before
    /// "Process(" / "Process.init" so only an actual `Process` type
    /// reference is flagged.
    private static func hasProcessConfig(_ sourceText: String) -> Bool {
        sourceText.range(of: #"(^|[^A-Za-z0-9_])Process(\(|\.init)"#, options: .regularExpression) != nil
    }

    private static func subprocessConfig(_ sourceText: String) -> Config? {
        if let m = firstCapture(#"URL\(fileURLWithPath:\s*"([^"]+)"\)\s*\.appendingPathComponent\("([^"]+)"\)"#, in: sourceText, groups: 2) {
            let base = m[0].hasSuffix("/") ? String(m[0].dropLast()) : m[0]
            return config(executable: base + "/" + m[1], sourceText: sourceText)
        }
        if let m = firstCapture(#"executableURL\s*=\s*URL\(fileURLWithPath:\s*"([^"]+)"\)"#, in: sourceText, groups: 1) {
            return config(executable: m[0], sourceText: sourceText)
        }
        // executableURL assigned from something that is not a literal.
        return nil
    }

    private static func config(executable: String, sourceText: String) -> Config {
        guard let interior = firstCapture(#"arguments\s*=\s*\[([^\]]*)\]"#, in: sourceText, groups: 1)?.first else {
            return Config(executable: executable, firstArgument: nil, arguments: [])
        }
        let args = allCaptures(#""([^"]*)""#, in: interior)
        return Config(executable: executable, firstArgument: args.first, arguments: args)
    }

    private static func firstCapture(_ pattern: String, in text: String, groups: Int) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1...groups).map { ns.substring(with: match.range(at: $0)) }
    }

    private static func allCaptures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }
}

// MARK: - Criterion 12: the paired CI signing step, scoped to a fixture
// fragment. YAML is scanned as text -- step (2b) does not apply, since
// YAML carries no Swift string literals. Wiring this over the real
// workflow file is round B.
enum CISigningStepCheck {
    static func check(_ yamlText: String) -> Bool {
        for step in steps(in: yamlText) {
            if step.contains("name: Signing argv test"), step.contains("run: make signing-test") {
                return true
            }
        }
        return false
    }

    /// Splits a workflow's `steps:` list into per-step text blocks on a
    /// `- name:`/`- run:`/`- uses:` boundary: a new list item at the same
    /// indent as the block's opening dash starts a new step.
    private static func steps(in yamlText: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        for line in yamlText.components(separatedBy: "\n") {
            let trimmedLeading = line.drop { $0 == " " }
            if trimmedLeading.hasPrefix("- ") {
                if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }
}

// MARK: - Criterion 6 probe (e): the shipped verifier spawns nothing.
// Deny-by-default token list ((e-1)/(e-2)) plus a TRANSITIVE single-file
// symbol-reachability closure ((e-3)), scoped to grading a standalone
// fixture specimen. Wiring this over the real Sources/ file is round B.
enum DefaultVerifySpawnCheck {
    static let spawnIdentifiers = [
        "Process", "NSTask", "posix_spawn", "system", "popen", "fork",
        "execv", "execve", "execvp", "NSWorkspace", "DispatchQueue.global",
    ]
    /// Repo-declared symbols known to be part of the Security-framework
    /// surface a compliant verifier is built on; not flagged as an
    /// out-of-file reference by the (e-3) closure.
    static let knownFrameworkSymbols: Set<String> = [
        "SecStaticCodeCreateWithPath", "SecRequirementCreateWithString",
        "SecStaticCodeCheckValidity", "URL", "CFURL",
        "SecCodeCopySelf", "SecCodeCopyStaticCode", "SecCodeCopyDesignatedRequirement",
        "hasSuffix", "fileExists",
    ]
    private static let controlFlowKeywords: Set<String> = [
        "if", "guard", "while", "for", "switch", "catch", "return", "let", "var",
    ]

    static func check(_ sourceText: String, label: String) -> String? {
        let text = SourceTextMatcher.run(sourceText).postLiteralStripNormalized
        for identifier in spawnIdentifiers where matchesIdentifier(identifier, in: text) {
            return "Expectation failed: \(label) references \"\(identifier)\", expected none: nonfunctional clause 3 forbids the shipped verifier to spawn a subprocess"
        }
        if let literal = assembledSystemPath(in: text) {
            return "Expectation failed: \(label) references an assembled system path \"\(literal)\", expected none: nonfunctional clause 3 forbids the shipped verifier to spawn a subprocess"
        }
        if let outOfFile = transitiveOutOfFileSymbol(sourceText) {
            return "Expectation failed: defaultVerify reaches \(outOfFile.symbol) declared outside \(label) via \(outOfFile.path): this single-file probe cannot see whether it spawns a subprocess"
        }
        return nil
    }

    private static func matchesIdentifier(_ identifier: String, in text: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: identifier) + "\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func assembledSystemPath(in text: String) -> String? {
        let pattern = #"fileURLWithPath:\s*"((usr|bin|sbin|Applications)[^"]*)""#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    private static func transitiveOutOfFileSymbol(_ sourceText: String) -> (symbol: String, path: String)? {
        walkClosure(sourceText).failure
    }

    /// The (e-3) walk's visited set, exposed so a test can assert the
    /// closure actually reaches a specific in-file member rather than
    /// merely failing to flag anything (6a-ii: a member reached only
    /// through a spelling the walk cannot see must fail here instead of
    /// passing silently).
    static func reached(_ sourceText: String) -> Set<String> {
        walkClosure(sourceText).visited
    }

    /// Shared (e-3) walk. Handles three identifier classes `calledIdentifiers`
    /// captures but that are not themselves out-of-file symbols (6a-iii):
    /// (alpha) an undotted callee that is a parameter name of the function
    /// being walked is admitted and not followed; (beta) a dotted callee is
    /// resolved through its second segment when the first is `self`/`Self`/
    /// `TrustedApplicationGate`, else the LAST segment must be an allowlisted
    /// framework symbol or the whole dotted name is flagged; (gamma) a bare
    /// identifier used as a default-argument value in the walked function's
    /// own signature is enqueued exactly like a called identifier.
    private static func walkClosure(_ sourceText: String) -> (failure: (symbol: String, path: String)?, visited: Set<String>) {
        let declared = declaredFunctionBodies(sourceText)
        let signatures = declaredFunctionSignatures(sourceText)
        guard let entry = declared["defaultVerify"] else { return (nil, []) }
        var visited: Set<String> = ["defaultVerify"]
        var worklist: [(name: String, body: String, path: String)] = [("defaultVerify", entry, "defaultVerify")]
        while !worklist.isEmpty {
            let (name, body, path) = worklist.removeFirst()
            let params = parameterNames(signatures[name] ?? "")
            var callees = calledIdentifiers(body)
            callees.append(contentsOf: defaultArgumentIdentifiers(signatures[name] ?? ""))
            for callee in callees {
                if visited.contains(callee) { continue }
                let segments = callee.components(separatedBy: ".")
                if segments.count > 1 {
                    let first = segments[0]
                    if first == "self" || first == "Self" || first == "TrustedApplicationGate" {
                        let inner = segments[1]
                        if visited.contains(inner) { continue }
                        if let calleeBody = declared[inner] {
                            visited.insert(inner)
                            worklist.append((inner, calleeBody, path + " -> " + inner))
                        } else if !knownFrameworkSymbols.contains(inner) {
                            return ((inner, path + " -> " + inner), visited)
                        }
                        continue
                    }
                    if let last = segments.last, knownFrameworkSymbols.contains(last) { continue }
                    return ((callee, path + " -> " + callee), visited)
                }
                if params.contains(callee) { continue }
                if let calleeBody = declared[callee] {
                    visited.insert(callee)
                    worklist.append((callee, calleeBody, path + " -> " + callee))
                } else if !knownFrameworkSymbols.contains(callee) {
                    return ((callee, path + " -> " + callee), visited)
                }
            }
        }
        return (nil, visited)
    }

    /// Internal parameter names parsed from a declared function's raw
    /// signature text (top-level comma split, paren-depth aware): the
    /// identifier immediately before each parameter's `:`.
    private static func parameterNames(_ signature: String) -> Set<String> {
        var names: Set<String> = []
        var depth = 0
        var current = ""
        var chunks: [String] = []
        for ch in signature {
            if ch == "(" { depth += 1 }
            if ch == ")" { depth -= 1 }
            if ch == "," && depth == 0 {
                chunks.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        chunks.append(current)
        for chunk in chunks {
            guard let colonIndex = chunk.firstIndex(of: ":") else { continue }
            let before = chunk[chunk.startIndex..<colonIndex]
            let tokens = before.split(whereSeparator: { $0.isWhitespace })
            if let last = tokens.last { names.insert(String(last)) }
        }
        return names
    }

    /// Bare identifiers used as a default-argument value in a signature
    /// (`= copySelfStaticCode`), which the closure enqueues even though
    /// nothing calls them by name (6a-iii gamma).
    private static func defaultArgumentIdentifiers(_ signature: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"=\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:,|\))"#) else { return [] }
        let ns = signature as NSString
        var result: [String] = []
        for match in regex.matches(in: signature, range: NSRange(location: 0, length: ns.length)) {
            result.append(ns.substring(with: match.range(at: 1)))
        }
        return result
    }

    /// Maps every `func`/`static func` name declared in `sourceText` to its
    /// paren-balanced raw parameter-list text (including the closing
    /// paren), used by `parameterNames` and `defaultArgumentIdentifiers`.
    private static func declaredFunctionSignatures(_ sourceText: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: #"(?:static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#) else { return result }
        let ns = sourceText as NSString
        for match in regex.matches(in: sourceText, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            guard let matchRange = Range(match.range, in: sourceText) else { continue }
            let openParenIndex = sourceText.index(before: matchRange.upperBound)
            var depth = 0
            var i = openParenIndex
            var endIdx: String.Index?
            while i < sourceText.endIndex {
                if sourceText[i] == "(" { depth += 1 }
                if sourceText[i] == ")" {
                    depth -= 1
                    if depth == 0 { endIdx = i; break }
                }
                i = sourceText.index(after: i)
            }
            guard let endIdx else { continue }
            let start = sourceText.index(after: openParenIndex)
            result[name] = String(sourceText[start...endIdx])
        }
        return result
    }

    /// Maps every `func`/`static func` name declared in `sourceText` to its
    /// brace-balanced body text.
    private static func declaredFunctionBodies(_ sourceText: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let regex = try? NSRegularExpression(pattern: #"(?:static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^)]*\)[^{]*\{"#) else { return result }
        let ns = sourceText as NSString
        for match in regex.matches(in: sourceText, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            guard let matchRange = Range(match.range, in: sourceText) else { continue }
            let braceIndex = sourceText.index(before: matchRange.upperBound)
            var depth = 0
            var i = braceIndex
            var endIdx: String.Index?
            while i < sourceText.endIndex {
                if sourceText[i] == "{" { depth += 1 }
                if sourceText[i] == "}" {
                    depth -= 1
                    if depth == 0 { endIdx = i; break }
                }
                i = sourceText.index(after: i)
            }
            guard let endIdx else { continue }
            let bodyStart = sourceText.index(after: braceIndex)
            result[name] = String(sourceText[bodyStart..<endIdx])
        }
        return result
    }

    private static func calledIdentifiers(_ body: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\b([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*\("#) else { return [] }
        let ns = body as NSString
        var result: [String] = []
        for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: match.range(at: 1))
            if !controlFlowKeywords.contains(name) { result.append(name) }
        }
        return result
    }
}

/// (A3) The graded fixture run: each probe's fixture-scoped matcher
/// against the sixteen never-compiled `static-assertions` specimens.
@Suite struct StaticAssertionFixtureRunTests {
    private static var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/static-assertions")
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: Self.fixturesDir.appendingPathComponent(name), encoding: .utf8)
    }

    // Probe (h), via the shared match procedure with the v13
    // interpolation-retention correction.

    @Test func gPlus1ProbeBAsRequiredPassesProbeH() throws {
        let (refs, unresolved) = ProbeHCheck.executableReferences(try read("probe-b-as-required.swift.txt"))
        #expect(refs.isEmpty && unresolved.isEmpty)
    }

    @Test func gPlus2ProbeHSelfPassesProbeH() throws {
        let (refs, unresolved) = ProbeHCheck.executableReferences(try read("probe-h-self.swift.txt"))
        #expect(refs.isEmpty && unresolved.isEmpty)
    }

    @Test func gMinus1DefaultOnRejectCalledFailsProbeH() throws {
        let (refs, unresolved) = ProbeHCheck.executableReferences(try read("defaultOnReject-called.swift.txt"))
        #expect(unresolved.isEmpty)
        #expect(refs.count == 2, "expected two executable references (direct call and interpolation call), found \(refs.count)")
    }

    // Criterion 9's inventory, scoped to a standalone fixture specimen.

    @Test func gPlus3SecurityReadOnlyMultilinePassesInventory() throws {
        #expect(SecurityInventoryCheck.check(try read("security-read-only-multiline.swift.txt")) == nil)
    }

    @Test func gPlus4CodesignSpecimenPassesInventory() throws {
        #expect(SecurityInventoryCheck.check(try read("codesign-specimen.swift.txt")) == nil)
    }

    @Test func gMinus2SecurityMutatingMultilineFailsInventory() throws {
        #expect(SecurityInventoryCheck.check(try read("security-mutating-multiline.swift.txt")) != nil)
    }

    @Test func gMinus3SecurityComponentBuiltFailsInventory() throws {
        #expect(SecurityInventoryCheck.check(try read("security-component-built.swift.txt")) != nil)
    }

    @Test func gMinus5SecurityUnresolvedFailsInventoryAsUnresolved() throws {
        let verdict = SecurityInventoryCheck.check(try read("security-unresolved.swift.txt"))
        #expect(verdict?.contains("cannot resolve the subprocess configuration") == true)
    }

    // Criterion 12's paired YAML probe, scoped to a fixture fragment.

    @Test func gPlus5CiSigningStepPresentPasses() throws {
        #expect(CISigningStepCheck.check(try read("ci-signing-step-present.yml.txt")) == true)
    }

    @Test func gMinus6CiSigningStepRenamedFails() throws {
        #expect(CISigningStepCheck.check(try read("ci-signing-step-renamed.yml.txt")) == false)
    }

    @Test func gMinus7CiSigningStepUnpairedFails() throws {
        #expect(CISigningStepCheck.check(try read("ci-signing-step-unpaired.yml.txt")) == false)
    }

    // Criterion 6 probe (e), the shipped verifier spawns nothing.

    @Test func gPlus6DefaultVerifyCompliantPassesSpawnCheck() throws {
        #expect(DefaultVerifySpawnCheck.check(try read("defaultVerify-compliant.swift.txt"), label: "fixture") == nil)
    }

    @Test func gMinus4ProcessInitNoParenFailsSpawnCheck() throws {
        #expect(DefaultVerifySpawnCheck.check(try read("process-init-no-paren.swift.txt"), label: "fixture") != nil)
    }

    @Test func gMinus8ProcessLiteralParenFailsSpawnCheck() throws {
        #expect(DefaultVerifySpawnCheck.check(try read("process-literal-paren.swift.txt"), label: "fixture") != nil)
    }

    @Test func gMinus9DirectOutOfFileHelperFailsSpawnCheckAtDepthOne() throws {
        let verdict = DefaultVerifySpawnCheck.check(try read("defaultVerify-direct-out-of-file-helper.swift.txt"), label: "fixture")
        #expect(verdict?.contains("defaultVerify -> ") == true)
    }

    @Test func gMinus10TransitiveOutOfFileHelperFailsSpawnCheckAsTransitiveClosure() throws {
        let verdict = DefaultVerifySpawnCheck.check(try read("defaultVerify-transitive-out-of-file-helper.swift.txt"), label: "fixture")
        #expect(verdict?.contains("defaultVerify -> localHelper -> ") == true)
    }
}
