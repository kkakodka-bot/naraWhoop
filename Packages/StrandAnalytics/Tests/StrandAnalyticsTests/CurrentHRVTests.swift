import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class CurrentHRVTests: XCTestCase {
    func testProvenFullWindowPreservesTrueZero() throws {
        let r = try XCTUnwrap(CurrentHRV.derive(observations: hrvEvidence(), nowUnix: 300))
        XCTAssertEqual(r.rmssdMs, 0); XCTAssertEqual(r.cleanBeats, 300); XCTAssertEqual(r.coverage, 1)
    }
    func testCleanHighVariabilitySurvives() throws {
        let r = try XCTUnwrap(CurrentHRV.derive(observations: hrvEvidence(pattern: [600, 1400]), nowUnix: 599))
        XCTAssertEqual(r.rmssdMs, 800)
    }
    func testLatestCompletedWindowCannotBorrowOldOrFutureData() {
        XCTAssertNil(CurrentHRV.derive(observations: hrvEvidence(start: -300) + hrvEvidence(start: 300), nowUnix: 300))
        XCTAssertNil(CurrentHRV.derive(observations: hrvEvidence(count: 30), nowUnix: 300))
    }
    func testLegacyRowsDoNotProveConsecutiveOriginalBeats() {
        XCTAssertNil(CurrentHRV.derive(rows: (0..<300).map { RRInterval(ts: $0, rrMs: 1000) }, nowUnix: 300))
    }
}
