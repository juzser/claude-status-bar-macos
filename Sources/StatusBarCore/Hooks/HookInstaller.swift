import Foundation

public enum HookInstallError: Error, Equatable {
    case invalidSettingsJSON
}

/// File-level orchestration: backup -> merge -> validate -> atomic write.
public struct HookInstaller {
    let settingsFile: URL
    let now: () -> Date

    public init(settingsFile: URL, now: @escaping () -> Date = Date.init) {
        self.settingsFile = settingsFile
        self.now = now
    }

    public func status(binaryPath: String) throws -> Bool {
        HookSettingsMerger.isInstalled(try readSettings(), binaryPath: binaryPath)
    }

    public func install(binaryPath: String) throws {
        try mutate { HookSettingsMerger.install(into: $0, binaryPath: binaryPath) }
    }

    public func uninstall() throws {
        try mutate { HookSettingsMerger.remove(from: $0) }
    }

    private func mutate(_ transform: ([String: Any]) -> [String: Any]) throws {
        if let existing = try? Data(contentsOf: settingsFile) {
            let backup = settingsFile.deletingLastPathComponent().appendingPathComponent(
                "\(settingsFile.lastPathComponent).claude-status-bar-backup-\(ISO8601.string(from: now()))")
            try AtomicFile.write(existing, to: backup)
        }
        let merged = transform(try readSettings())
        guard JSONSerialization.isValidJSONObject(merged) else {
            throw HookInstallError.invalidSettingsJSON
        }
        let data = try JSONSerialization.data(
            withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try AtomicFile.write(data, to: settingsFile)
    }

    private func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsFile), !data.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallError.invalidSettingsJSON
        }
        return obj
    }
}
