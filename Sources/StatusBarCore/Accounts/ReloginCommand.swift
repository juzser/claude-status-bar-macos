import Foundation

/// Builds the shell command that re-authenticates an account whose token was
/// rejected. Neither cux nor this app has a one-shot login: for a cux-managed
/// slot the flow is `cux switch <slot>` (make it the live account) then
/// `cux /login` (Claude Code's login flow under the wrapper, which syncs the
/// fresh token back to the slot). The bare ~/.claude account logs in via
/// `claude /login` directly.
public enum ReloginCommand {
    public static func command(for account: Account) -> String {
        if let slot = account.slot {
            return "cux switch \(slot) && cux /login"
        }
        return "claude /login"
    }
}
