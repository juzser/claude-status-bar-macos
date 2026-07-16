import Foundation
import Testing
@testable import StatusBarCore

@Suite struct ReloginCommandTests {
    @Test func returnsPlainLoginCommandForAnyAccount() {
        let slotted = Account(id: "native-0", alias: nil, email: "a@example.com", slot: 0,
                              isActive: true, oauthURL: URL(fileURLWithPath: "/dev/null"))
        #expect(ReloginCommand.command(for: slotted) == "claude /login")

        let plain = Account(id: "default", alias: nil, email: nil, slot: nil,
                            isActive: true, oauthURL: URL(fileURLWithPath: "/dev/null"))
        #expect(ReloginCommand.command(for: plain) == "claude /login")
    }
}
