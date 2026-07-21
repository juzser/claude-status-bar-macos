import Foundation

/// Parses/validates the `"schema": "name@major"` convention used by every
/// token-slayer JSON document. A minor-version bump is forward-compatible
/// (additive fields only); a major-version bump is not, so `matches` only
/// ever compares name + major.
public enum TokenSlayerSchema {
    public static func parse(_ raw: String) -> (name: String, major: Int)? {
        guard let atIndex = raw.lastIndex(of: "@") else { return nil }
        let name = String(raw[raw.startIndex..<atIndex])
        let majorString = raw[raw.index(after: atIndex)...]
        guard !name.isEmpty, let major = Int(majorString) else { return nil }
        return (name, major)
    }

    public static func matches(_ obj: [String: Any], name: String, major: Int) -> Bool {
        guard let raw = obj["schema"] as? String, let parsed = parse(raw) else { return false }
        return parsed.name == name && parsed.major == major
    }
}

public struct SlayerUsageWindow: Equatable, Sendable {
    public let utilization: Double
    public let resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct SlayerUsage: Equatable, Sendable {
    public let fiveHour: SlayerUsageWindow?
    public let sevenDay: SlayerUsageWindow?
    public let polledAt: Date?
    public let tokenExpired: Bool

    public init(fiveHour: SlayerUsageWindow?, sevenDay: SlayerUsageWindow?,
                polledAt: Date?, tokenExpired: Bool) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.polledAt = polledAt
        self.tokenExpired = tokenExpired
    }

    fileprivate static func parse(_ any: Any?) -> SlayerUsage? {
        guard let dict = any as? [String: Any] else { return nil }
        return SlayerUsage(
            fiveHour: window(from: dict["five_hour"]),
            sevenDay: window(from: dict["seven_day"]),
            polledAt: unixDate(dict["polled_at"]),
            tokenExpired: (dict["token_expired"] as? Bool) ?? false
        )
    }

    private static func window(from any: Any?) -> SlayerUsageWindow? {
        guard let dict = any as? [String: Any] else { return nil }
        guard let number = dict["utilization"] as? NSNumber else { return nil }
        return SlayerUsageWindow(utilization: number.doubleValue, resetsAt: unixDate(dict["resets_at"]))
    }

    private static func unixDate(_ any: Any?) -> Date? {
        guard let number = any as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }
}

public struct SlayerAccount: Equatable, Sendable {
    public let index: Int
    public let name: String
    public let alias: String?
    public let email: String?
    public let orgUuid: String?
    public let uuid: String?
    public let plan: String?
    public let active: Bool
    public let state: String
    public let usage: SlayerUsage?

    public init(index: Int, name: String, alias: String?, email: String?, orgUuid: String?,
                uuid: String?, plan: String?, active: Bool, state: String, usage: SlayerUsage?) {
        self.index = index
        self.name = name
        self.alias = alias
        self.email = email
        self.orgUuid = orgUuid
        self.uuid = uuid
        self.plan = plan
        self.active = active
        self.state = state
        self.usage = usage
    }

    fileprivate static func parse(_ dict: [String: Any]) -> SlayerAccount? {
        guard let index = (dict["index"] as? NSNumber)?.intValue,
              let name = dict["name"] as? String,
              let active = dict["active"] as? Bool,
              let state = dict["state"] as? String
        else { return nil }
        return SlayerAccount(
            index: index, name: name,
            alias: dict["alias"] as? String, email: dict["email"] as? String,
            orgUuid: dict["org_uuid"] as? String, uuid: dict["uuid"] as? String,
            plan: dict["plan"] as? String, active: active, state: state,
            usage: SlayerUsage.parse(dict["usage"])
        )
    }
}

/// `token-slayer list --json` / `status --json` response (schema `accounts@1`).
public struct SlayerAccountsDoc: Equatable, Sendable {
    public let active: String?
    public let accounts: [SlayerAccount]

    public init(active: String?, accounts: [SlayerAccount]) {
        self.active = active
        self.accounts = accounts
    }

    /// Tolerant parse: unknown/additive fields are ignored; a wrong schema
    /// name or major version, or malformed JSON, returns nil.
    public static func parse(_ data: Data) -> SlayerAccountsDoc? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              TokenSlayerSchema.matches(obj, name: "accounts", major: 1),
              let rawAccounts = obj["accounts"] as? [[String: Any]]
        else { return nil }
        let accounts = rawAccounts.compactMap(SlayerAccount.parse)
        return SlayerAccountsDoc(active: obj["active"] as? String, accounts: accounts)
    }
}

public struct SlayerSession: Equatable, Sendable {
    public let sessionId: String
    public let billedAccount: String?

    public init(sessionId: String, billedAccount: String?) {
        self.sessionId = sessionId
        self.billedAccount = billedAccount
    }

    fileprivate static func parse(_ dict: [String: Any]) -> SlayerSession? {
        guard let sessionId = dict["session_id"] as? String else { return nil }
        return SlayerSession(sessionId: sessionId, billedAccount: dict["billed_account"] as? String)
    }
}

/// `token-slayer sessions --json` response (schema `sessions@1`).
public struct SlayerSessionsDoc: Equatable, Sendable {
    public let sessions: [SlayerSession]

    public init(sessions: [SlayerSession]) {
        self.sessions = sessions
    }

    public static func parse(_ data: Data) -> SlayerSessionsDoc? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              TokenSlayerSchema.matches(obj, name: "sessions", major: 1),
              let rawSessions = obj["sessions"] as? [[String: Any]]
        else { return nil }
        return SlayerSessionsDoc(sessions: rawSessions.compactMap(SlayerSession.parse))
    }
}

/// Joins `sessions --json` output onto hook-tracked session rows. Only
/// sessions with a non-nil `billed_account` contribute an entry — slayer-only
/// `ide:*` helper rows (which never have a hook-tracked counterpart, and
/// always report a nil `billed_account`) are naturally excluded, as is any
/// other session with no billed account yet.
public enum SlayerSessionJoin {
    public static func billedAccounts(from sessions: [SlayerSession]) -> [String: String] {
        var result: [String: String] = [:]
        for session in sessions {
            guard let billedAccount = session.billedAccount else { continue }
            result[session.sessionId] = billedAccount
        }
        return result
    }
}
