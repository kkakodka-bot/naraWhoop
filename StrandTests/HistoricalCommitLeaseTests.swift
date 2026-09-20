import XCTest
@testable import Strand

@MainActor
final class HistoricalCommitLeaseTests: XCTestCase {
    func testExpirationBeforeIdentifierInstallationEndsExactlyOnce() {
        var events: [String] = []
        let lease = HistoricalCommitLease(begin: { expire in expire(); return 7 },
            end: { events.append("end:\($0)") }, expired: { events.append("fence") })
        lease.finish()
        lease.finish(expiring: true)
        XCTAssertEqual(events, ["fence", "end:7"])
    }
    func testCompletionThenExpirationDoesNotFenceNextChunk() {
        var callback: (() -> Void)?
        var ended = 0, expired = 0
        let lease = HistoricalCommitLease(begin: { callback = $0; return 1 },
            end: { _ in ended += 1 }, expired: { expired += 1 })
        lease.finish()
        callback?()
        lease.finish()
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(expired, 0)
    }
    func testAcquisitionFailureFencesWithoutEndingInvalidIdentifier() {
        var fenced = false
        let lease = HistoricalCommitLease(begin: { _ in nil }, end: { _ in XCTFail() }, expired: { fenced = true })
        lease.finish()
        XCTAssertTrue(fenced)
    }
}
