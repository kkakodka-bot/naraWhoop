import Foundation
import XCTest
@testable import StrandDesign

final class WatchContextOutboxTests: XCTestCase {
    func testResetReplacesPreviousAccountAndSurvivesInactiveSession() {
        var outbox = WatchContextOutbox()
        outbox.enqueue(Data("account-a-scores".utf8))
        let reset = Data("signed-out-empty-context".utf8)
        outbox.enqueue(reset)
        var sent: [Data] = []
        XCTAssertFalse(outbox.flush(activated: false) { sent.append($0) })
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(outbox.pending, reset)
        XCTAssertTrue(outbox.flush(activated: true) { sent.append($0) })
        XCTAssertEqual(sent, [reset])
        XCTAssertNil(outbox.pending)
        XCTAssertFalse(outbox.flush(activated: true) { sent.append($0) })
    }

    func testFailedUpdateRetainsOnlyLatestContextForRetry() {
        enum Failure: Error { case unavailable }
        var outbox = WatchContextOutbox()
        outbox.enqueue(Data([1]))
        XCTAssertFalse(outbox.flush(activated: true) { _ in throw Failure.unavailable })
        XCTAssertEqual(outbox.pending, Data([1]))
        outbox.enqueue(Data([2]))
        XCTAssertTrue(outbox.flush(activated: true) { XCTAssertEqual($0, Data([2])) })
        XCTAssertNil(outbox.pending)
    }
}
