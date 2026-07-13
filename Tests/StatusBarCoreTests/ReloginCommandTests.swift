import Foundation
import Testing
@testable import StatusBarCore

@Suite struct ReloginCommandTests {
    @Test func cuxAccountSwitchesSlotThenLogsIn() {
        let account = Account(id: "slot-2", alias: "work", email: "a@b.com", slot: 2,
                              isActive: false, oauthURL: URL(fileURLWithPath: "/tmp/oauth.json"))
        #expect(ReloginCommand.command(for: account) == "cux switch 2 && cux /login")
    }

    @Test func defaultAccountLogsInViaClaude() {
        let account = Account(id: "default", alias: nil, email: nil, slot: nil,
                              isActive: true, oauthURL: URL(fileURLWithPath: "/tmp/credentials.json"))
        #expect(ReloginCommand.command(for: account) == "claude /login")
    }
}
