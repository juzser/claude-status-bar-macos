import Foundation
import Testing
@testable import StatusBarCore

@Suite struct HexColorTests {
    @Test func parsesRRGGBB() {
        let c = HexColor.components(hex: "#34C759")
        #expect(c != nil)
        #expect(abs(c!.r - Double(0x34) / 255) < 0.001)
        #expect(abs(c!.g - Double(0xC7) / 255) < 0.001)
        #expect(abs(c!.b - Double(0x59) / 255) < 0.001)
    }

    @Test func parsesWithoutLeadingHash() {
        #expect(HexColor.components(hex: "34C759") != nil)
    }

    @Test func lowercaseHexParses() {
        #expect(HexColor.components(hex: "#34c759") != nil)
    }

    @Test func malformedHexReturnsNil() {
        #expect(HexColor.components(hex: "#ZZZZZZ") == nil)
        #expect(HexColor.components(hex: "#ABC") == nil)
        #expect(HexColor.components(hex: "") == nil)
    }

    @Test func formatsRoundTrip() {
        let hex = HexColor.hex(r: Double(0x34) / 255, g: Double(0xC7) / 255, b: Double(0x59) / 255)
        #expect(hex == "#34C759")
    }

    @Test func formatClampsOutOfRangeComponents() {
        #expect(HexColor.hex(r: -1, g: 2, b: 0.5) == "#00FF80")
    }
}
