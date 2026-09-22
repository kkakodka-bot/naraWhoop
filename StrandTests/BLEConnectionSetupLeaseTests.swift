import XCTest
@testable import Strand

@MainActor
final class BLEConnectionSetupLeaseTests: XCTestCase {
    func testDeadlineFencesBeforeEndingAndAllCompletionsAreExactlyOnce() {
        var deadline: (() -> Void)?, expiration: (() -> Void)?
        var events: [String] = []
        let lease = BLEConnectionSetupLease(begin: { expiration = $0; return 7 },
            end: { events.append("end:\($0)") }, schedule: { seconds, callback in
                XCTAssertEqual(seconds, 20); deadline = callback
                return { events.append("cancel") }
            }, failed: { events.append($0.rawValue) })
        deadline?(); expiration?(); lease.finish()
        XCTAssertTrue(lease.isFinished)
        XCTAssertEqual(events, ["cancel", "deadline", "end:7"])
    }

    func testReadinessCancelsDeadlineAndLateExpirationDoesNothing() {
        var deadline: (() -> Void)?, expiration: (() -> Void)?
        var ended = 0, cancelled = 0
        let lease = BLEConnectionSetupLease(begin: { expiration = $0; return 1 },
            end: { _ in ended += 1 }, schedule: { _, callback in deadline = callback; return { cancelled += 1 } },
            failed: { _ in XCTFail("Ready connection must not be cancelled") })
        lease.finish(); deadline?(); expiration?(); lease.finish()
        XCTAssertEqual(ended, 1); XCTAssertEqual(cancelled, 1)
    }

    func testSynchronousExpirationBeforeAssertionReturnsIsExactlyOnce() {
        var events: [String] = []
        let lease = BLEConnectionSetupLease(begin: { expired in expired(); return 2 },
            end: { events.append("end:\($0)") }, schedule: { _, _ in XCTFail(); return {} },
            failed: { events.append($0.rawValue) })
        lease.finish()
        XCTAssertEqual(events, ["assertionExpired", "end:2"])
    }

    func testBackgroundAssertionDenialFailsBeforeScheduling() {
        var failures: [BLEConnectionSetupLease.Failure] = []
        let lease = BLEConnectionSetupLease(begin: { _ in nil }, end: { _ in XCTFail() },
            schedule: { _, _ in XCTFail(); return {} }, failed: { failures.append($0) })
        lease.finish()
        XCTAssertEqual(failures, [.assertionDenied])
    }

    func testForegroundAssertionDenialAllowsSetupButBackgroundTransitionFences() {
        var background: (() -> Void)?, deadline: (() -> Void)?
        var failures: [BLEConnectionSetupLease.Failure] = [], cancelled = 0
        let lease = BLEConnectionSetupLease(begin: { _ in nil }, end: { _ in XCTFail() },
            schedule: { _, callback in deadline = callback; return { cancelled += 1 } },
            foregroundFallback: { callback in background = callback; return { cancelled += 1 } },
            failed: { failures.append($0) })
        XCTAssertFalse(lease.isFinished)
        background?(); deadline?(); lease.finish()
        XCTAssertEqual(failures, [.backgroundWithoutAssertion]); XCTAssertEqual(cancelled, 2)
    }

    func testMacOSStyleAssertionWithoutExpirationStillHasFiniteDeadline() {
        var deadline: (() -> Void)?
        var failures: [BLEConnectionSetupLease.Failure] = []
        let lease = BLEConnectionSetupLease(begin: { _ in 0 }, end: { _ in },
            schedule: { _, callback in deadline = callback; return {} }, failed: { failures.append($0) })
        XCTAssertFalse(lease.isFinished)
        deadline?()
        XCTAssertEqual(failures, [.deadline])
    }
}
