import Foundation

/// Resolves the SwiftPM resource bundle (Clawd PNGs) without going through
/// the accessor SwiftPM auto-generates per target (a `Bundle` extension
/// exposing a static `module` property). That accessor only tries (a)
/// `Bundle.main.bundleURL` — the .app package ROOT for an installed app,
/// where codesign forbids loose content, so `scripts/make-app.sh` correctly
/// places the bundle under `Contents/Resources/` instead and this lookup
/// always misses — then (b) a build-machine-absolute path baked in at
/// compile time, then `Swift.fatalError()`. That crashes the app on first
/// icon render on every machine except the one it was built on.
///
/// This resolver checks the locations that actually exist in both shipped
/// and dev layouts and returns nil instead of crashing when neither has the
/// bundle, so callers can fall back to SF Symbols.
enum ResourceBundle {
    private static let bundleName = "claude-status-bar-macos_ClaudeStatusBar.bundle"

    /// Resolved once and cached; the candidates are static for the process lifetime.
    static let resolved: Bundle? = {
        let candidates = [
            Bundle.main.resourceURL,  // installed .app: Contents/Resources
            Bundle.main.bundleURL,    // `swift run` / `swift build`: bundle sits next to the executable
        ]
        for base in candidates {
            guard let base else { continue }
            let url = base.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }()
}
