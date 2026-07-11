import Foundation
import Testing
@testable import StatusBarCore

@Suite struct AppPathsTests {
    @Test func explicitRootWins() {
        let root = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let paths = AppPaths(root: root, environment: ["CLAUDE_STATUS_BAR_HOME": "/elsewhere"])
        #expect(paths.root == root)
    }

    @Test func envOverridesDefault() {
        let paths = AppPaths(environment: ["CLAUDE_STATUS_BAR_HOME": "/tmp/env-home"])
        #expect(paths.root.path == "/tmp/env-home")
    }

    @Test func defaultIsUnderApplicationSupport() {
        let paths = AppPaths(environment: [:])
        #expect(paths.root.path.hasSuffix("Application Support/ClaudeStatusBar"))
    }

    @Test func derivedPaths() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/x", isDirectory: true))
        #expect(paths.sessionsDir.path == "/tmp/x/sessions")
        #expect(paths.usageCacheFile.path == "/tmp/x/usage-cache.json")
    }

    @Test func ensureDirsCreatesSessionsDir() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("paths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let paths = AppPaths(root: tmp)
        try paths.ensureDirs()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: paths.sessionsDir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }
}

@Suite struct AtomicFileTests {
    @Test func writesCreatesDirsAndOverwrites() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("atomic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = tmp.appendingPathComponent("nested").appendingPathComponent("out.json")
        try AtomicFile.write(Data("one".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one")
        try AtomicFile.write(Data("two".utf8), to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "two")
        let dir = file.deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == ["out.json"])  // no temp files left behind
    }
}

@Suite struct ISO8601Tests {
    @Test func parsesPlainAndFractional() {
        #expect(ISO8601.parse("2026-07-10T03:00:00Z") != nil)
        #expect(ISO8601.parse("2026-07-10T03:00:00.123Z") != nil)
        #expect(ISO8601.parse("garbage") == nil)
    }

    @Test func roundTrips() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ISO8601.parse(ISO8601.string(from: date)) == date)
    }
}
