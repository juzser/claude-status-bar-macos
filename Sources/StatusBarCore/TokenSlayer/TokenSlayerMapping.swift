import Foundation

/// Maps token-slayer's own account/usage shape onto this app's existing
/// `Account` / `AccountUsageState` types, so the rest of the app (menu-bar
/// label, popover rows, threshold coloring) needs no slayer-specific
/// branching downstream of this layer.
public enum TokenSlayerMapping {
    /// `uuid` when present, else the (unique) slot `name` — matches the
    /// contract's own note that `name` is the stable, always-present
    /// identifier while `uuid` may be null for a not-yet-fully-provisioned
    /// account.
    public static func accountId(for slayer: SlayerAccount) -> String {
        slayer.uuid ?? slayer.name
    }

    /// Collapses accounts that resolve to the same `accountId(for:)` (e.g.
    /// two slots sharing a `uuid` because one was re-added under a new
    /// `name` while the old slot is still present) down to one entry per id
    /// — the CLI's own list order decides the winner, last one in wins.
    /// Required before building any `[id: ...]` dictionary from a slayer
    /// account list: `Dictionary(uniqueKeysWithValues:)` traps on a
    /// duplicate key, and the CLI's contract doesn't guarantee `uuid`
    /// uniqueness across slots.
    public static func dedupedById(_ accounts: [SlayerAccount]) -> [SlayerAccount] {
        var order: [String] = []
        var byId: [String: SlayerAccount] = [:]
        for account in accounts {
            let id = accountId(for: account)
            if byId[id] == nil { order.append(id) }
            byId[id] = account
        }
        return order.compactMap { byId[$0] }
    }

    /// `slot` is set to the slayer `index` purely so `AccountsSection`'s
    /// existing "has a slot → eligible for a Switch button" gate passes; the
    /// actual switch target is always `slayer.name` (index is documented as
    /// unstable), tracked separately by the caller.
    public static func account(from slayer: SlayerAccount) -> Account {
        Account(
            id: accountId(for: slayer),
            alias: slayer.alias,
            email: slayer.email,
            slot: slayer.index,
            isActive: slayer.active,
            oauthURL: URL(fileURLWithPath: "/dev/null"),
            organizationUuid: slayer.orgUuid
        )
    }

    /// `needsRelogin` is true when the account's own `state` is `"expired"`
    /// or its usage snapshot reports an expired token — either condition
    /// alone is sufficient.
    ///
    /// `freshness` is `.fresh` whenever `usage` is present at all, regardless
    /// of whether it came from a cached `list --json` or a live `status
    /// --json` call: the existing UI dims a row via `.opacity(0.5)` whenever
    /// freshness isn't `.fresh`, and popover-open always uses the cached
    /// `list --json` call by design — treating that as `.stale` would dim
    /// the entire accounts section on every single popover open.
    public static func usageState(from slayer: SlayerAccount) -> AccountUsageState {
        let needsRelogin = slayer.state == "expired" || (slayer.usage?.tokenExpired ?? false)
        guard let usage = slayer.usage else {
            return AccountUsageState(snapshot: nil, freshness: .none, needsRelogin: needsRelogin)
        }
        let snapshot = UsageSnapshot(
            fiveHour: usage.fiveHour.map { UsageWindow(utilization: $0.utilization, resetsAt: $0.resetsAt) },
            sevenDay: usage.sevenDay.map { UsageWindow(utilization: $0.utilization, resetsAt: $0.resetsAt) },
            fetchedAt: usage.polledAt ?? Date()
        )
        return AccountUsageState(snapshot: snapshot, freshness: .fresh, needsRelogin: needsRelogin)
    }
}
