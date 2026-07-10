import Foundation

public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let root {
            self.root = root
        } else if let env = environment["CLAUDE_STATUS_BAR_HOME"], !env.isEmpty {
            self.root = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            self.root = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ClaudeStatusBar", isDirectory: true)
        }
    }

    public var sessionsDir: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    public var usageCacheFile: URL {
        root.appendingPathComponent("usage-cache.json")
    }

    public func ensureDirs() throws {
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }
}
