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

    @Test func policyRequirementIsExactlyPinnedLiteral() {
        #expect(TrustedApplicationGate.policyRequirement == "certificate leaf[subject.CN] exists")
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
            postLiteralStripNormalized: normalizeWhitespace(literalStripped),
            literalStrippedWithNewlines: literalStripped,
            unresolved: unresolved)
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

    private static func hasProcessConfig(_ sourceText: String) -> Bool {
        sourceText.contains("Process(") || sourceText.contains("Process.init")
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
        let declared = declaredFunctionBodies(sourceText)
        guard let entry = declared["defaultVerify"] else { return nil }
        var visited: Set<String> = ["defaultVerify"]
        var worklist: [(name: String, body: String, path: String)] = [("defaultVerify", entry, "defaultVerify")]
        while !worklist.isEmpty {
            let (_, body, path) = worklist.removeFirst()
            for callee in calledIdentifiers(body) {
                if visited.contains(callee) { continue }
                if let calleeBody = declared[callee] {
                    visited.insert(callee)
                    worklist.append((callee, calleeBody, path + " -> " + callee))
                } else if !knownFrameworkSymbols.contains(callee) {
                    return (callee, path + " -> " + callee)
                }
            }
        }
        return nil
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
