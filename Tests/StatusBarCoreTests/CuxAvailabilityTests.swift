import Foundation
import Testing
@testable import StatusBarCore

@Suite("CuxAvailability")
struct CuxAvailabilityTests {
    @Test("returns true when one of the candidates is executable")
    func trueWhenCandidateExecutable() {
        let installed = CuxAvailability.isInstalled(
            candidates: ["/a/cux", "/b/cux"],
            isExecutable: { $0 == "/b/cux" }
        )
        #expect(installed == true)
    }

    @Test("returns false when none of the candidates are executable")
    func falseWhenNoCandidateExecutable() {
        let installed = CuxAvailability.isInstalled(
            candidates: ["/a/cux", "/b/cux"],
            isExecutable: { _ in false }
        )
        #expect(installed == false)
    }

    @Test("returns false for an empty candidates list")
    func falseWhenCandidatesEmpty() {
        let installed = CuxAvailability.isInstalled(
            candidates: [],
            isExecutable: { _ in true }
        )
        #expect(installed == false)
    }
}
