import Foundation
import Security
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

    // MARK: - Finding #2: defaultReader was the only Sec* call site with no
    // kSecUseAuthenticationUI flag at all — it runs every poll cycle for
    // every inactive account and during every switch, making it the most
    // likely source of real, unattributed prompts. performRead makes that
    // non-interactive by default; allowInteractive: true is the opt-in
    // reserved for the vault's own repair path (mirrors AccountDiscovery's
    // performKeychainRead / defaultInteractiveKeychainReader split).

    @Test func performReadSetsAuthenticationUIFailByDefault() {
        var capturedQuery: [String: Any]?
        _ = AccountCredentialVault.performRead(service: "svc", accountId: "acct") { query, _ in
            capturedQuery = query as? [String: Any]
            return errSecItemNotFound
        }
        let authUI = capturedQuery?[kSecUseAuthenticationUI as String] as? String
        #expect(authUI == (kSecUseAuthenticationUIFail as String))
    }

    @Test func performReadOmitsAuthenticationUIFailWhenInteractive() {
        var capturedQuery: [String: Any]?
        _ = AccountCredentialVault.performRead(service: "svc", accountId: "acct", allowInteractive: true) { query, _ in
            capturedQuery = query as? [String: Any]
            return errSecItemNotFound
        }
        #expect(capturedQuery?[kSecUseAuthenticationUI as String] == nil)
    }

    @Test func performReadReportsStatusThroughOnStatusCallback() {
        var reported: KeychainStatus?
        _ = AccountCredentialVault.performRead(
            service: "svc", accountId: "acct", onStatus: { reported = $0 }
        ) { _, _ in errSecInteractionNotAllowed }
        #expect(reported == .interactionNotAllowed)
    }

    @Test func performReadReturnsDataOnSuccess() {
        let payload = Data("vault-data".utf8)
        let result = AccountCredentialVault.performRead(service: "svc", accountId: "acct") { _, item in
            item?.pointee = payload as CFTypeRef
            return errSecSuccess
        }
        #expect(result == payload)
    }

    @Test func defaultReaderCompilesAndReturnsNilForAbsentTestItem() {
        // No injectable seam of its own (production wiring): confirms it
        // routes through the non-interactive performRead rather than
        // crashing, against a real, presumably-absent test account.
        let result = AccountCredentialVault.defaultReader(
            service: "com.claude-status-bar.does-not-exist-test-only", accountId: "does-not-exist")
        #expect(result == nil)
    }

    // MARK: - isAlreadyTrusted / repairRead / repairReadWithStatus
    //
    // Same shape as LiveCredentialWriter's trust probe + repair read: a
    // non-interactive probe gates whether the (interactive) repair path
    // needs to run at all, so an already-trusted vault item's ACL is never
    // needlessly rewritten.

    @Test func isAlreadyTrustedDelegatesToInjectedProber() {
        let result = AccountCredentialVault.isAlreadyTrusted(accountId: "acct", prober: { _, accountId in
            accountId == "acct"
        })
        #expect(result)
    }

    @Test func isAlreadyTrustedReturnsFalseWhenProberFails() {
        #expect(AccountCredentialVault.isAlreadyTrusted(accountId: "acct", prober: { _, _ in false }) == false)
    }

    @Test func repairReadDelegatesToInjectedReader() {
        let result = AccountCredentialVault.repairRead(accountId: "acct", reader: { _, accountId in
            accountId == "acct" ? Data("token".utf8) : nil
        })
        #expect(result == Data("token".utf8))
    }

    @Test func repairReadWithStatusPassesThroughStatus() {
        let result = AccountCredentialVault.repairReadWithStatus(accountId: "acct", reader: { _, _ in
            (nil, .interactionNotAllowed)
        })
        #expect(result.data == nil)
        #expect(result.status == .interactionNotAllowed)
    }

    @Test func defaultInteractiveReaderWithStatusCompilesAndReportsItemNotFound() {
        let result = AccountCredentialVault.defaultInteractiveReaderWithStatus(
            service: "com.claude-status-bar.does-not-exist-test-only", accountId: "does-not-exist")
        #expect(result.data == nil)
    }

    // MARK: - repairWrite
    //
    // Unlike defaultWriter (a plain delete-then-add with the implicit
    // system-default ACL), repairWrite mirrors LiveCredentialWriter.
    // performWrite: it builds an explicit SecAccess naming trustedPaths, so
    // this is the one place that actually re-establishes the vault item's
    // trust rather than relying on whatever ACL SecItemAdd assigned it the
    // first time.

    @Test func repairWritePassesDataServiceAccountIdAndTrustedPathsThrough() {
        var captured: (Data, String, String, [String])?
        let ok = AccountCredentialVault.repairWrite(
            accountId: "native-0", Data("token".utf8), trustedPaths: ["/Applications/ClaudeStatusBar.app"]
        ) { data, service, accountId, trustedPaths in
            captured = (data, service, accountId, trustedPaths)
            return true
        }
        #expect(ok)
        #expect(captured?.0 == Data("token".utf8))
        #expect(captured?.1 == AccountCredentialVault.service)
        #expect(captured?.2 == "native-0")
        #expect(captured?.3 == ["/Applications/ClaudeStatusBar.app"])
    }

    @Test func repairWriteFailsWhenWriterFails() {
        let ok = AccountCredentialVault.repairWrite(accountId: "native-0", Data(), trustedPaths: []) { _, _, _, _ in false }
        #expect(ok == false)
    }

    @Test func performRepairWriteDeletesExistingItemBeforeAdding() {
        var deleteCalled = false
        _ = AccountCredentialVault.performRepairWrite(
            data: Data("token".utf8), service: "svc", accountId: "acct", trustedPaths: [],
            add: { _, _ in errSecSuccess },
            delete: { _ in deleteCalled = true; return errSecSuccess }
        )
        #expect(deleteCalled)
    }

    @Test func performRepairWriteSetsExplicitAccessAndAuthenticationUIAllow() {
        var capturedAttributes: [String: Any]?
        _ = AccountCredentialVault.performRepairWrite(
            data: Data("token".utf8), service: "svc", accountId: "acct",
            trustedPaths: ["/Applications/ClaudeStatusBar.app"],
            add: { attributes, _ in
                capturedAttributes = attributes as? [String: Any]
                return errSecSuccess
            },
            delete: { _ in errSecSuccess }
        )
        #expect(capturedAttributes?[kSecAttrAccess as String] != nil)
        let authUI = capturedAttributes?[kSecUseAuthenticationUI as String] as? String
        #expect(authUI == (kSecUseAuthenticationUIAllow as String))
        #expect(capturedAttributes?[kSecAttrAccessible as String] as? String
                == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
    }

    @Test func performRepairWriteReturnsFalseWhenAddFails() {
        let ok = AccountCredentialVault.performRepairWrite(
            data: Data("token".utf8), service: "svc", accountId: "acct", trustedPaths: [],
            add: { _, _ in errSecDuplicateItem },
            delete: { _ in errSecSuccess }
        )
        #expect(ok == false)
    }
}
