import Testing
@testable import JalanKitaKit

@Suite struct SeverityTests {
    @Test func scoreBands() {
        #expect(Severity(score: 0) == .urgent)
        #expect(Severity(score: 39) == .urgent)
        #expect(Severity(score: 40) == .monitor)
        #expect(Severity(score: 69) == .monitor)
        #expect(Severity(score: 70) == .ignore)
        #expect(Severity(score: 100) == .ignore)
    }
}
