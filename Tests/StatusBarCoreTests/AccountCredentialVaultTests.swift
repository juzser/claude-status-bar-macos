import Foundation
import Testing
@testable import StatusBarCore

@Suite struct AccountCredentialVaultTests {
    @Test func writeThenReadRoundTripsThroughInjectedStorage() {
        var storage: [String: Data] = [:]
        let writer: (Data, String, String) -> Bool = { data, service, account in
            storage["\(service)/\(account)"] = data
            return true
        }
        let reader: (String, String) -> Data? = { service, account in
            storage["\(service)/\(account)"]
        }

        let backup = CredentialBackup(liveCredentials: Data("creds".utf8),
                                      oauthAccountBlock: Data("oauth".utf8))
        #expect(AccountCredentialVault.write(accountId: "native-0", backup, writer: writer))

        let read = AccountCredentialVault.read(accountId: "native-0", reader: reader)
        #expect(read == backup)
    }

    @Test func readReturnsNilWhenNothingStored() {
        let reader: (String, String) -> Data? = { _, _ in nil }
        #expect(AccountCredentialVault.read(accountId: "missing", reader: reader) == nil)
    }

    @Test func writeFailsWhenWriterFails() {
        let writer: (Data, String, String) -> Bool = { _, _, _ in false }
        let backup = CredentialBackup(liveCredentials: Data("creds".utf8), oauthAccountBlock: nil)
        #expect(AccountCredentialVault.write(accountId: "native-0", backup, writer: writer) == false)
    }

    @Test func oauthAccountBlockRoundTripsAsNil() {
        var storage: [String: Data] = [:]
        let writer: (Data, String, String) -> Bool = { data, service, account in
            storage["\(service)/\(account)"] = data
            return true
        }
        let reader: (String, String) -> Data? = { service, account in
            storage["\(service)/\(account)"]
        }
        let backup = CredentialBackup(liveCredentials: Data("creds".utf8), oauthAccountBlock: nil)
        #expect(AccountCredentialVault.write(accountId: "native-0", backup, writer: writer))
        #expect(AccountCredentialVault.read(accountId: "native-0", reader: reader)?.oauthAccountBlock == nil)
    }

    @Test func serviceNameIsStable() {
        #expect(AccountCredentialVault.service == "ClaudeStatusBar-backup")
    }
}
