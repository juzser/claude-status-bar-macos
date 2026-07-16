import Foundation

/// One-time migration of cux-managed accounts into `NativeAccountStore`.
/// Runs whenever `native-accounts.json` doesn't exist yet; a no-op forever
/// after (even if cux is later uninstalled).
public enum CuxStateImporter {
    public static func importIfNeeded(
        cuxRoot: URL,
        nativeStateFile: URL,
        vaultWrite: (String, CredentialBackup) -> Bool = { AccountCredentialVault.write(accountId: $0, $1) },
        keychainReader: (String) -> Data? = { AccountDiscovery.defaultKeychainReader(service: $0) }
    ) {
        guard !NativeAccountStore.exists(file: nativeStateFile) else { return }

        let discovered = AccountDiscovery.discover(cuxRoot: cuxRoot,
                                                    credentialsFile: URL(fileURLWithPath: "/dev/null"))
        let slotAccounts = discovered.filter { $0.slot != nil }
        guard !slotAccounts.isEmpty else { return }

        var accounts: [NativeAccount] = []
        var activeId: String?

        for account in slotAccounts {
            guard let slot = account.slot else { continue }
            let email = account.email ?? ""
            let backupLabel = cuxBackupLabel(slot: slot, email: email)
            let oauthFile = cuxRoot.appendingPathComponent("accounts", isDirectory: true)
                .appendingPathComponent(String(format: "%02d-%@", slot, email))
                .appendingPathComponent("oauth.json")
            let oauthBlock = try? Data(contentsOf: oauthFile)

            let needsRelogin: Bool
            if let liveCreds = keychainReader(backupLabel) {
                let backup = CredentialBackup(liveCredentials: liveCreds, oauthAccountBlock: oauthBlock)
                needsRelogin = !vaultWrite(account.id, backup)
            } else {
                needsRelogin = true
            }

            accounts.append(NativeAccount(id: account.id, alias: account.alias, email: account.email,
                                          slot: slot, organizationUuid: account.organizationUuid,
                                          needsRelogin: needsRelogin))
            if account.isActive { activeId = account.id }
        }

        guard !accounts.isEmpty else { return }
        try? NativeAccountStore.save(NativeAccountState(activeId: activeId, accounts: accounts), to: nativeStateFile)
    }

    static func cuxBackupLabel(slot: Int, email: String) -> String {
        "cux-backup-\(String(format: "%02d", slot))-\(email)"
    }
}
