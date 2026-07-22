import Testing
@testable import StatusBarCore

@Test func versionIsSet() {
    #expect(StatusBarCoreInfo.version == "1.0.1")
}
