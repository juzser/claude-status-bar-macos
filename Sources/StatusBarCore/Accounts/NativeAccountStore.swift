import Foundation

public struct NativeAccount: Codable, Sendable, Equatable {
    public var id: String
    public var alias: String?
    public var email: String?
    public var slot: Int
    public var organizationUuid: String?
    public var needsRelogin: Bool

    public init(id: String, alias: String?, email: String?, slot: Int,
                organizationUuid: String?, needsRelogin: Bool) {
        self.id = id
        self.alias = alias
        self.email = email
        self.slot = slot
        self.organizationUuid = organizationUuid
        self.needsRelogin = needsRelogin
    }
}

public struct NativeAccountState: Codable, Sendable, Equatable {
    public var activeId: String?
    public var accounts: [NativeAccount]

    public init(activeId: String? = nil, accounts: [NativeAccount] = []) {
        self.activeId = activeId
        self.accounts = accounts
    }
}

/// Persists the app's own account list at `native-accounts.json` under
/// `AppPaths().root` — this app's sole on-disk record of which accounts
/// exist and which one is active.
public enum NativeAccountStore {
    public static func exists(file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    public static func load(file: URL) -> NativeAccountState {
        guard let data = try? Data(contentsOf: file),
              let state = try? JSONDecoder().decode(NativeAccountState.self, from: data)
        else { return NativeAccountState() }
        return state
    }

    public static func save(_ state: NativeAccountState, to file: URL) throws {
        let data = try JSONEncoder().encode(state)
        try AtomicFile.write(data, to: file)
    }

    public static func nextSlot(in state: NativeAccountState) -> Int {
        (state.accounts.map(\.slot).max() ?? -1) + 1
    }

    public static func toAccount(_ account: NativeAccount, state: NativeAccountState) -> Account {
        Account(id: account.id, alias: account.alias, email: account.email, slot: account.slot,
                isActive: account.id == state.activeId,
                oauthURL: URL(fileURLWithPath: "/dev/null"),
                organizationUuid: account.organizationUuid)
    }

    public static func toAccounts(_ state: NativeAccountState) -> [Account] {
        state.accounts.sorted { $0.slot < $1.slot }.map { toAccount($0, state: state) }
    }
}
