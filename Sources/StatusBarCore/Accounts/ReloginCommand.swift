import Foundation

/// Builds the shell command that re-authenticates an account whose token was
/// rejected. Under the native account switching model, the app ensures the
/// target account is live in-process via `AppState.switchAccount` before
/// invoking this command, so the command itself is always just `claude /login`.
public enum ReloginCommand {
    public static func command(for account: Account) -> String {
        "claude /login"
    }
}
