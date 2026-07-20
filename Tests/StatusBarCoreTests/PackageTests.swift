import Testing
@testable import StatusBarCore

@Test func versionIsSet() {
    #expect(StatusBarCoreInfo.version == "0.1.10")
}
