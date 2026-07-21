import Foundation
import Testing
@testable import StatusBarCore

@Suite struct TokenSlayerSchemaTests {
    @Test func parsesNameAndMajor() {
        let parsed = TokenSlayerSchema.parse("accounts@1")
        #expect(parsed?.name == "accounts")
        #expect(parsed?.major == 1)
    }

    @Test func returnsNilForMalformedSchemaString() {
        #expect(TokenSlayerSchema.parse("accounts") == nil)
        #expect(TokenSlayerSchema.parse("accounts@one") == nil)
        #expect(TokenSlayerSchema.parse("") == nil)
    }

    @Test func matchesExpectsExactNameAndMajor() {
        let obj: [String: Any] = ["schema": "accounts@1"]
        #expect(TokenSlayerSchema.matches(obj, name: "accounts", major: 1))
        #expect(!TokenSlayerSchema.matches(obj, name: "accounts", major: 2))
        #expect(!TokenSlayerSchema.matches(obj, name: "sessions", major: 1))
    }

    @Test func matchesFailsWhenSchemaKeyMissingOrWrongType() {
        #expect(!TokenSlayerSchema.matches([:], name: "accounts", major: 1))
        #expect(!TokenSlayerSchema.matches(["schema": 1], name: "accounts", major: 1))
    }
}

@Suite struct SlayerAccountsDocTests {
    // The contract sample from the task, plus a second account exercising
    // every nullable field (alias/email/org_uuid/uuid/plan/usage all nil).
    private static let fixture = """
    {"schema":"accounts@1","namespace":"token_slayer","active":"work","generated_at":123,
     "accounts":[
       {"index":1,"name":"work","alias":"w","email":"a@x.com","org_uuid":"o1","uuid":"u1",
        "plan":"claude_max","active":true,"state":"active",
        "usage":{"five_hour":{"utilization":42.0,"resets_at":100},
                 "seven_day":{"utilization":18.0,"resets_at":200},
                 "polled_at":50,"token_expired":false}},
       {"index":2,"name":"spare","alias":null,"email":null,"org_uuid":null,"uuid":null,
        "plan":null,"active":false,"state":"ready","usage":null}
     ]}
    """.data(using: .utf8)!

    @Test func decodesAccountsWithFullyPopulatedFields() {
        let doc = SlayerAccountsDoc.parse(Self.fixture)
        #expect(doc?.active == "work")
        #expect(doc?.accounts.count == 2)
        let work = doc?.accounts.first
        #expect(work?.index == 1)
        #expect(work?.name == "work")
        #expect(work?.alias == "w")
        #expect(work?.email == "a@x.com")
        #expect(work?.orgUuid == "o1")
        #expect(work?.uuid == "u1")
        #expect(work?.plan == "claude_max")
        #expect(work?.active == true)
        #expect(work?.state == "active")
        #expect(work?.usage?.fiveHour?.utilization == 42.0)
        #expect(work?.usage?.fiveHour?.resetsAt == Date(timeIntervalSince1970: 100))
        #expect(work?.usage?.sevenDay?.utilization == 18.0)
        #expect(work?.usage?.sevenDay?.resetsAt == Date(timeIntervalSince1970: 200))
        #expect(work?.usage?.polledAt == Date(timeIntervalSince1970: 50))
        #expect(work?.usage?.tokenExpired == false)
    }

    @Test func decodesAccountsWithAllNullableFieldsMissing() {
        let doc = SlayerAccountsDoc.parse(Self.fixture)
        let spare = doc?.accounts.last
        #expect(spare?.name == "spare")
        #expect(spare?.alias == nil)
        #expect(spare?.email == nil)
        #expect(spare?.orgUuid == nil)
        #expect(spare?.uuid == nil)
        #expect(spare?.plan == nil)
        #expect(spare?.active == false)
        #expect(spare?.state == "ready")
        #expect(spare?.usage == nil)
    }

    @Test func toleratesAdditiveUnknownFields() {
        let withExtra = """
        {"schema":"accounts@1","active":"work","future_field":"whatever",
         "accounts":[{"index":1,"name":"work","alias":null,"email":null,"org_uuid":null,
                      "uuid":null,"plan":null,"active":true,"state":"active",
                      "usage":null,"future_account_field":42}]}
        """.data(using: .utf8)!
        let doc = SlayerAccountsDoc.parse(withExtra)
        #expect(doc?.accounts.first?.name == "work")
    }

    @Test func rejectsWrongMajorSchemaVersion() {
        let wrongMajor = """
        {"schema":"accounts@2","active":null,"accounts":[]}
        """.data(using: .utf8)!
        #expect(SlayerAccountsDoc.parse(wrongMajor) == nil)
    }

    @Test func rejectsMismatchedSchemaName() {
        let wrongName = """
        {"schema":"sessions@1","active":null,"accounts":[]}
        """.data(using: .utf8)!
        #expect(SlayerAccountsDoc.parse(wrongName) == nil)
    }

    @Test func rejectsMalformedJSON() {
        #expect(SlayerAccountsDoc.parse(Data("not json".utf8)) == nil)
    }
}

@Suite struct SlayerSessionsDocTests {
    // Mirrors the contract sample: a regular interactive session with a
    // billed_account, one with billed_account null, and an `ide:*` helper
    // entry (also null billed_account, per the contract's field notes).
    private static let fixture = """
    {"schema":"sessions@1","sessions":[
      {"session_id":"11111111-1111-1111-1111-111111111111","pid":123,
       "billed_account":"work","cwd":"/path","git_branch":"x","started_at":1,
       "wrapper_state":null,"kind":"interactive","native_status":"busy",
       "ide_name":null,"status":"thinking","model":"claude-opus-4-8","last_activity":2},
      {"session_id":"22222222-2222-2222-2222-222222222222","pid":124,
       "billed_account":null,"cwd":"/path2","git_branch":null,"started_at":3,
       "wrapper_state":null,"kind":"interactive","native_status":null,
       "ide_name":null,"status":null,"model":null,"last_activity":null},
      {"session_id":"ide:19950","pid":19950,"billed_account":null,"cwd":"/path3",
       "git_branch":null,"started_at":4,"wrapper_state":null,"kind":"ide",
       "native_status":null,"ide_name":"vscode","status":null,"model":null,
       "last_activity":null}
    ]}
    """.data(using: .utf8)!

    @Test func decodesSessionIdAndBilledAccount() {
        let doc = SlayerSessionsDoc.parse(Self.fixture)
        #expect(doc?.sessions.count == 3)
        #expect(doc?.sessions[0].sessionId == "11111111-1111-1111-1111-111111111111")
        #expect(doc?.sessions[0].billedAccount == "work")
    }

    @Test func decodesNullBilledAccount() {
        let doc = SlayerSessionsDoc.parse(Self.fixture)
        #expect(doc?.sessions[1].billedAccount == nil)
    }

    @Test func decodesIdeHelperEntryLikeAnyOtherSession() {
        let doc = SlayerSessionsDoc.parse(Self.fixture)
        #expect(doc?.sessions[2].sessionId == "ide:19950")
        #expect(doc?.sessions[2].billedAccount == nil)
    }

    @Test func rejectsWrongMajorSchemaVersion() {
        let wrongMajor = Data("""
        {"schema":"sessions@2","sessions":[]}
        """.utf8)
        #expect(SlayerSessionsDoc.parse(wrongMajor) == nil)
    }
}

@Suite struct SlayerSessionJoinTests {
    @Test func mapsOnlySessionsWithNonNilBilledAccount() {
        let sessions = [
            SlayerSession(sessionId: "a", billedAccount: "work"),
            SlayerSession(sessionId: "b", billedAccount: nil),
            SlayerSession(sessionId: "ide:19950", billedAccount: nil),
        ]
        let joined = SlayerSessionJoin.billedAccounts(from: sessions)
        #expect(joined == ["a": "work"])
    }

    @Test func emptyInputProducesEmptyMap() {
        #expect(SlayerSessionJoin.billedAccounts(from: []).isEmpty)
    }
}
