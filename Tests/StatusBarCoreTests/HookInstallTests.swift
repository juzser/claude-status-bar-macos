import Foundation
import Testing
@testable import StatusBarCore

private let bin = "/Applications/ClaudeStatusBar.app/Contents/MacOS/claude-status-hook"

@Suite struct HookSettingsMergerTests {
    @Test func installIntoEmptySettings() throws {
        let merged = HookSettingsMerger.install(into: [:], binaryPath: bin)
        let hooks = try #require(merged["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookSettingsMerger.events))

        let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 1)
        #expect(pre[0]["matcher"] as? String == "*")
        let entry = try #require((pre[0]["hooks"] as? [[String: Any]])?.first)
        #expect(entry["type"] as? String == "command")
        #expect(entry["command"] as? String == "\(bin) PreToolUse")

        // Non-tool events carry no matcher key
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop[0]["matcher"] == nil)
    }

    @Test func installPreservesForeignHooksAndIsIdempotent() throws {
        let foreign: [String: Any] = [
            "model": "opus",
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/guard.sh"]]]
                ]
            ],
        ]
        let once = HookSettingsMerger.install(into: foreign, binaryPath: bin)
        let twice = HookSettingsMerger.install(into: once, binaryPath: bin)

        #expect(twice["model"] as? String == "opus")
        let pre = try #require((twice["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 2)  // foreign + exactly one of ours
        let commands = pre.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands.filter { $0.contains("claude-status-hook") }.count == 1)
        #expect(commands.contains("/usr/local/bin/guard.sh"))
    }

    @Test func removeDropsOnlyOursAndCleansEmpties() throws {
        let foreign: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/local/bin/guard.sh"]]]
                ]
            ]
        ]
        let installed = HookSettingsMerger.install(into: foreign, binaryPath: bin)
        let removed = HookSettingsMerger.remove(from: installed)

        let hooks = try #require(removed["hooks"] as? [String: Any])
        #expect(hooks["Stop"] == nil)          // ours-only event fully dropped
        let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 1)                // foreign entry survives

        // Removing from a settings dict where we're the ONLY content drops "hooks" entirely
        let onlyOurs = HookSettingsMerger.install(into: [:], binaryPath: bin)
        #expect(HookSettingsMerger.remove(from: onlyOurs)["hooks"] == nil)
    }

    @Test func removeMatchesStaleBinaryPaths() {
        let old = HookSettingsMerger.install(into: [:], binaryPath: "/old/path/claude-status-hook")
        #expect(HookSettingsMerger.remove(from: old)["hooks"] == nil)
    }

    @Test func isInstalledChecksAllEvents() {
        #expect(!HookSettingsMerger.isInstalled([:], binaryPath: bin))
        let full = HookSettingsMerger.install(into: [:], binaryPath: bin)
        #expect(HookSettingsMerger.isInstalled(full, binaryPath: bin))
        let partial = HookSettingsMerger.remove(from: full)
        #expect(!HookSettingsMerger.isInstalled(partial, binaryPath: bin))
    }
}

@Suite struct HookInstallerTests {
    private func tempSettingsFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @Test func installCreatesBackupAndValidJSON() throws {
        let file = tempSettingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try AtomicFile.write(Data(#"{"model":"opus"}"#.utf8), to: file)

        let fixed = Date(timeIntervalSince1970: 1_750_000_000)
        let installer = HookInstaller(settingsFile: file, now: { fixed })
        try installer.install(binaryPath: bin)

        #expect(try installer.status(binaryPath: bin))
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(written?["model"] as? String == "opus")

        let backup = file.deletingLastPathComponent()
            .appendingPathComponent("settings.json.claude-status-bar-backup-\(ISO8601.string(from: fixed))")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try Data(contentsOf: backup) == Data(#"{"model":"opus"}"#.utf8))
    }

    @Test func installOnMissingFileStartsFresh() throws {
        let file = tempSettingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let installer = HookInstaller(settingsFile: file)
        try installer.install(binaryPath: bin)
        #expect(try installer.status(binaryPath: bin))
    }

    @Test func uninstallRestoresForeignOnlySettings() throws {
        let file = tempSettingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try AtomicFile.write(Data(#"{"model":"opus"}"#.utf8), to: file)
        let installer = HookInstaller(settingsFile: file)
        try installer.install(binaryPath: bin)
        try installer.uninstall()

        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(after?["model"] as? String == "opus")
        #expect(after?["hooks"] == nil)
        #expect(try !installer.status(binaryPath: bin))
    }

    @Test func corruptSettingsFileThrowsWithoutWriting() throws {
        let file = tempSettingsFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try AtomicFile.write(Data("{broken".utf8), to: file)
        let installer = HookInstaller(settingsFile: file)
        #expect(throws: HookInstallError.self) { try installer.install(binaryPath: bin) }
        #expect(try Data(contentsOf: file) == Data("{broken".utf8))  // untouched
    }
}
