import Foundation
import XCTest
@testable import NoopPush

final class PushWakeBudgetTests: XCTestCase {
    func testBytesAndRequestCountAreIndependentAndFailedAdmissionConsumesNothing() {
        let budget = PushWakeBudget(rowsPerJob: 5_000, maximumPreparedBytes: 10,
            maximumWireBytes: 8, maximumRequests: 2, duration: 20, clock: { 100 })
        XCTAssertEqual(budget.rowsPerJob, 2_000)
        XCTAssertFalse(budget.admitPreparation(bytes: 11))
        XCTAssertTrue(budget.admitPreparation(bytes: 10))
        XCTAssertFalse(budget.permitsPreparation)
        XCTAssertFalse(budget.admitRequest(bytes: 9))
        XCTAssertTrue(budget.admitRequest(bytes: 8))
        XCTAssertTrue(budget.admitRequest(bytes: 0))
        XCTAssertFalse(budget.admitRequest(bytes: 0))
    }

    func testMonotonicDeadlineStopsPreparationAndTransferAdmission() {
        let clock = WakeBudgetClock()
        let budget = PushWakeBudget(duration: 20, clock: { clock.value })
        XCTAssertTrue(budget.permitsPreparation)
        XCTAssertTrue(budget.admitPreparation(bytes: 2))
        clock.set(20)
        XCTAssertFalse(budget.permitsPreparation)
        XCTAssertFalse(budget.admitPreparation(bytes: 1))
        XCTAssertFalse(budget.admitRequest(bytes: 0))
    }
}

private final class WakeBudgetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    var value: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func set(_ value: TimeInterval) { lock.lock(); time = value; lock.unlock() }
}
