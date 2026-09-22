import XCTest
@testable import Strand

@MainActor
final class BLENotificationControllerTests: XCTestCase {
    private let token = BLEConnectionOwner.Token(peripheralID: UUID(), generation: 1)

    func testCachedActiveWaitsForOffThenConfirmedOn() {
        let controller = BLENotificationController<String>()
        var effects: [Bool] = []
        let submit: (Bool) -> Bool = { effects.append($0); return true }
        XCTAssertTrue(controller.request("history", isNotifying: true, token: token, submit: submit))
        XCTAssertEqual(effects, [false])
        XCTAssertTrue(controller.confirmed.isEmpty)
        XCTAssertEqual(controller.observed("history", isNotifying: false, succeeded: true, token: token, submit: submit), .waiting)
        XCTAssertEqual(effects, [false, true])
        XCTAssertTrue(controller.confirmed.isEmpty)
        XCTAssertEqual(controller.observed("history", isNotifying: true, succeeded: true, token: token, submit: submit), .confirmed)
        XCTAssertEqual(controller.confirmed, ["history"])
    }

    func testOutOfOrderOnDoesNotConsumeDisableAndDuplicateOffDoesNotRepeatEnable() {
        let controller = BLENotificationController<String>()
        var effects: [Bool] = []
        let submit: (Bool) -> Bool = { effects.append($0); return true }
        controller.request("history", isNotifying: true, token: token, submit: submit)
        for _ in 0..<5 {
            XCTAssertEqual(controller.observed("history", isNotifying: true, succeeded: true, token: token, submit: submit), .waiting)
            XCTAssertTrue(controller.request("history", isNotifying: true, token: token, submit: submit))
        }
        XCTAssertEqual(effects, [false])
        XCTAssertTrue(controller.confirmed.isEmpty)
        for _ in 0..<5 {
            XCTAssertEqual(controller.observed("history", isNotifying: false, succeeded: true, token: token, submit: submit), .waiting)
        }
        XCTAssertEqual(effects, [false, true])
        XCTAssertTrue(controller.confirmed.isEmpty)
        XCTAssertEqual(controller.observed("history", isNotifying: true, succeeded: true, token: token, submit: submit), .confirmed)
    }

    func testFreshSubscriptionRequiresCallbackAndDuplicateOnIsIdempotent() {
        let controller = BLENotificationController<String>()
        var effects: [Bool] = []
        let submit: (Bool) -> Bool = { effects.append($0); return true }
        controller.request("history", isNotifying: false, token: token, submit: submit)
        controller.request("history", isNotifying: false, token: token, submit: submit)
        XCTAssertEqual(effects, [true])
        XCTAssertTrue(controller.confirmed.isEmpty)
        for _ in 0..<5 {
            XCTAssertEqual(controller.observed("history", isNotifying: true, succeeded: true, token: token, submit: submit), .confirmed)
        }
        controller.request("history", isNotifying: true, token: token, submit: submit)
        XCTAssertEqual(effects, [true])
        XCTAssertEqual(controller.confirmed, ["history"])
    }

    func testDisableErrorAndRejectedEnableRemainUnconfirmedAndRetryable() {
        let controller = BLENotificationController<String>()
        controller.request("history", isNotifying: true, token: token) { _ in true }
        XCTAssertEqual(controller.observed("history", isNotifying: true, succeeded: false, token: token) { _ in XCTFail(); return true }, .needsRecovery)
        XCTAssertTrue(controller.confirmed.isEmpty)
        controller.request("history", isNotifying: true, token: token) { _ in true }
        XCTAssertEqual(controller.observed("history", isNotifying: false, succeeded: true, token: token) { enabled in
            XCTAssertTrue(enabled); return false
        }, .needsRecovery)
        XCTAssertTrue(controller.confirmed.isEmpty)
        XCTAssertTrue(controller.request("history", isNotifying: false, token: token) { enabled in enabled })
    }

    func testRejectedInitialSubmissionCannotBeConfirmedByLaterCallback() {
        let controller = BLENotificationController<String>()
        XCTAssertFalse(controller.request("history", isNotifying: false, token: token) { _ in false })
        XCTAssertEqual(controller.observed("history", isNotifying: true, succeeded: true, token: token) { _ in true }, .ignored)
        XCTAssertTrue(controller.confirmed.isEmpty)
    }

    func testGenerationChangeDropsReadinessAndRejectsOldCallbacksAndRequests() {
        let controller = BLENotificationController<String>()
        controller.request("history", isNotifying: false, token: token) { _ in true }
        _ = controller.observed("history", isNotifying: true, succeeded: true, token: token) { _ in true }
        let newer = BLEConnectionOwner.Token(peripheralID: UUID(), generation: 2)
        controller.request("history", isNotifying: true, token: newer) { _ in true }
        XCTAssertTrue(controller.confirmed.isEmpty)
        XCTAssertEqual(controller.observed("history", isNotifying: true, succeeded: true, token: token) { _ in XCTFail(); return true }, .ignored)
        XCTAssertFalse(controller.request("history", isNotifying: false, token: token) { _ in XCTFail(); return true })
        XCTAssertEqual(controller.token, newer)
    }

    func testConfirmedSubscriptionLossNeedsBoundedOwnerRecovery() {
        let controller = BLENotificationController<String>()
        controller.request("history", isNotifying: false, token: token) { _ in true }
        _ = controller.observed("history", isNotifying: true, succeeded: true, token: token) { _ in true }
        XCTAssertEqual(controller.observed("history", isNotifying: false, succeeded: true, token: token) { _ in true }, .needsRecovery)
        XCTAssertTrue(controller.confirmed.isEmpty)
        XCTAssertEqual(controller.observed("history", isNotifying: false, succeeded: true, token: token) { _ in true }, .ignored)
    }

    func testResetAndUnrequestedChannelCannotAuthorizeHistory() {
        let controller = BLENotificationController<String>()
        controller.request("history", isNotifying: false, token: token) { _ in true }
        XCTAssertEqual(controller.observed("console", isNotifying: true, succeeded: true, token: token) { _ in true }, .ignored)
        controller.reset()
        XCTAssertEqual(controller.observed("history", isNotifying: true, succeeded: true, token: token) { _ in true }, .ignored)
        XCTAssertTrue(controller.confirmed.isEmpty)
    }
}
