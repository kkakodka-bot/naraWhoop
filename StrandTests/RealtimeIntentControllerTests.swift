import XCTest
@testable import Strand

@MainActor
final class RealtimeIntentControllerTests: XCTestCase {
    @MainActor private final class Transport {
        var requests: [RealtimeIntentController.Request] = []
        var failures: [RealtimeIntentController.Failure] = []
        var acceptsSubmission = true
        lazy var controller = RealtimeIntentController(submit: { [unowned self] request in
            requests.append(request)
            return acceptsSubmission
        }, recover: { [unowned self] in failures.append($0) })

        func connect(_ generation: UInt64 = 1, desired: Bool) {
            controller.setDesired(desired)
            controller.beginConnection(generation: generation)
            controller.setReady(true)
        }

        func complete(_ succeeded: Bool = true) {
            guard let pending = controller.pending else { XCTFail("Missing write"); return }
            controller.completed(pending, succeeded: succeeded)
        }
    }

    func testStopRemainsPendingUntilATTCompletionAndRetriesFailedATT() {
        let transport = Transport()
        transport.connect(desired: true)
        transport.complete()
        transport.controller.setDesired(false)
        XCTAssertEqual(transport.controller.confirmedEnabled, true)
        XCTAssertEqual(transport.requests.map(\.enabled), [true, false])
        transport.complete(false)
        XCTAssertNil(transport.controller.confirmedEnabled)
        XCTAssertEqual(transport.requests.map(\.enabled), [true, false, false])
        transport.complete()
        XCTAssertEqual(transport.controller.confirmedEnabled, false)
        XCTAssertNil(transport.controller.pending)
    }

    func testRepeatedWristChangesUseOnlyLatestIntentAfterPendingWrite() {
        let transport = Transport()
        transport.connect(desired: true)
        transport.complete()
        transport.controller.setDesired(false)
        transport.controller.setDesired(false)
        transport.controller.setDesired(true)
        transport.controller.setDesired(false)
        transport.complete()
        XCTAssertEqual(transport.requests.map(\.enabled), [true, false])
        transport.controller.setDesired(true)
        transport.complete()
        XCTAssertEqual(transport.requests.map(\.enabled), [true, false, true])
    }

    func testClosingLiveWhileOffWristDoesNotRecreateIntentOnCompletion() {
        let transport = Transport()
        transport.connect(desired: true)
        transport.controller.setDesired(false)
        transport.complete()
        XCTAssertEqual(transport.requests.map(\.enabled), [true, false])
        transport.controller.setDesired(false)
        transport.complete()
        transport.controller.reconcile()
        XCTAssertEqual(transport.requests.map(\.enabled), [true, false])
    }

    func testReconnectOffWristSubmitsStopEvenWhenPreviousStopWasConfirmed() {
        let transport = Transport()
        transport.connect(desired: false)
        transport.complete()
        transport.controller.endConnection()
        transport.controller.beginConnection(generation: 2)
        transport.controller.setReady(true)
        XCTAssertEqual(transport.requests.map(\.enabled), [false, false])
        XCTAssertEqual(transport.requests.last?.generation, 2)
    }

    func testOldGenerationAndDuplicateCompletionsCannotSettleNewWrite() {
        let transport = Transport()
        transport.connect(desired: true)
        let stale = transport.requests[0]
        transport.controller.endConnection()
        transport.connect(2, desired: false)
        let pending = transport.controller.pending
        transport.controller.completed(stale, succeeded: true)
        transport.controller.completed(stale, succeeded: false)
        XCTAssertEqual(transport.controller.pending, pending)
        XCTAssertNil(transport.controller.confirmedEnabled)
        transport.complete()
        transport.controller.completed(pending!, succeeded: false)
        XCTAssertEqual(transport.controller.confirmedEnabled, false)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testATTFailuresRequestOneRecoveryAfterBoundedAttempts() {
        let transport = Transport()
        transport.connect(desired: false)
        for _ in 0..<3 { transport.complete(false) }
        for _ in 0..<10 { transport.controller.reconcile() }
        transport.controller.setDesired(true)
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.failures, [.attWriteFailed])
        XCTAssertTrue(transport.controller.recoveryRequested)
    }

    func testSubmissionFailureWaitsForEventAndNeverClaimsConfirmedStop() {
        let transport = Transport()
        transport.acceptsSubmission = false
        transport.connect(desired: false)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertNil(transport.controller.confirmedEnabled)
        XCTAssertNil(transport.controller.pending)
        transport.controller.reconcile()
        transport.controller.reconcile()
        transport.controller.reconcile()
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(transport.failures, [.submissionRejected])
    }

    func testAccountAndDeviceTeardownFenceOldCompletionAndClearIntent() {
        let transport = Transport()
        transport.connect(desired: true)
        let stale = transport.requests[0]
        transport.controller.endConnection(clearIntent: true)
        transport.controller.completed(stale, succeeded: true)
        transport.controller.setReady(true)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertFalse(transport.controller.desiredEnabled)
        transport.controller.beginConnection(generation: 2)
        transport.controller.setReady(true)
        XCTAssertEqual(transport.requests.map(\.enabled), [true, false])
    }

    func testDuplicateReadyAndAttachDoNotResetPendingWrite() {
        let transport = Transport()
        transport.connect(desired: true)
        let pending = transport.controller.pending
        transport.controller.beginConnection(generation: 1)
        transport.controller.setReady(true)
        transport.controller.reconcile()
        XCTAssertEqual(transport.controller.pending, pending)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testIntentChangeWhileFailedEnableIsPendingSendsStopNext() {
        let transport = Transport()
        transport.connect(desired: true)
        transport.controller.setDesired(false)
        transport.complete(false)
        XCTAssertEqual(transport.requests.map(\.enabled), [true, false])
        transport.complete()
        XCTAssertEqual(transport.controller.confirmedEnabled, false)
        XCTAssertTrue(transport.failures.isEmpty)
    }

    func testTransportReadinessPreventsWritesBeforeBondAndAfterDisconnect() {
        let transport = Transport()
        transport.controller.beginConnection(generation: 1)
        transport.controller.setDesired(true)
        XCTAssertTrue(transport.requests.isEmpty)
        transport.controller.setReady(true)
        XCTAssertEqual(transport.requests.count, 1)
        transport.controller.endConnection()
        transport.controller.setDesired(false)
        transport.controller.reconcile()
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testContinuousIntentCanRemainOnWhenScreenIntentEnds() {
        let transport = Transport()
        transport.connect(desired: true)
        transport.complete()
        // Caller derives true because continuous capture still requests realtime.
        transport.controller.setDesired(true)
        XCTAssertEqual(transport.requests.map(\.enabled), [true])
        transport.controller.setDesired(false)
        transport.complete()
        XCTAssertEqual(transport.requests.map(\.enabled), [true, false])
    }

    func testRefreshReassertsConfirmedEnableWithOnlyOnePendingWrite() {
        let transport = Transport()
        transport.connect(desired: true)
        transport.complete()
        transport.controller.refreshEnabled()
        let refresh = transport.controller.pending
        XCTAssertEqual(transport.requests.map(\.enabled), [true, true])
        XCTAssertEqual(transport.controller.confirmedEnabled, true)
        XCTAssertNotEqual(transport.requests[0].sequence, refresh?.sequence)
        for _ in 0..<10 { transport.controller.refreshEnabled() }
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.controller.pending, refresh)
        transport.complete()
        transport.controller.refreshEnabled()
        XCTAssertEqual(transport.requests.map(\.enabled), [true, true, true])
    }

    func testRefreshNeverEnablesOffWristOrDuplicatesPendingStop() {
        let transport = Transport()
        transport.connect(desired: true)
        transport.complete()
        transport.controller.setDesired(false)
        for _ in 0..<10 { transport.controller.refreshEnabled() }
        XCTAssertEqual(transport.requests.map(\.enabled), [true, false])
        transport.complete()
        transport.controller.refreshEnabled()
        XCTAssertEqual(transport.requests.map(\.enabled), [true, false])
    }

    func testRefreshWhileEnablePendingDoesNotLeaveDeferredRefreshDebt() {
        let transport = Transport()
        transport.connect(desired: true)
        transport.controller.refreshEnabled()
        transport.controller.refreshEnabled()
        transport.complete()
        XCTAssertNil(transport.controller.pending)
        XCTAssertEqual(transport.requests.map(\.enabled), [true])
    }

    func testRefreshRespectsReadinessAndAccountTeardown() {
        let transport = Transport()
        transport.connect(desired: true)
        transport.complete()
        transport.controller.setReady(false)
        transport.controller.refreshEnabled()
        transport.controller.setReady(true)
        XCTAssertEqual(transport.requests.count, 1)
        transport.controller.endConnection(clearIntent: true)
        transport.controller.refreshEnabled()
        transport.controller.beginConnection(generation: 2)
        transport.controller.refreshEnabled()
        XCTAssertEqual(transport.requests.count, 1)
        transport.controller.setReady(true)
        XCTAssertEqual(transport.requests.map(\.enabled), [true, false])
    }

    func testOffWristDuringFailedRefreshSendsLatestStopInsteadOfRetryingEnable() {
        let transport = Transport()
        transport.connect(desired: true)
        transport.complete()
        transport.controller.refreshEnabled()
        transport.controller.setDesired(false)
        transport.complete(false)
        XCTAssertEqual(transport.requests.map(\.enabled), [true, true, false])
        transport.complete()
        transport.controller.refreshEnabled()
        XCTAssertEqual(transport.controller.confirmedEnabled, false)
        XCTAssertEqual(transport.requests.map(\.enabled), [true, true, false])
    }

    func testRefreshFailuresUseSameBoundedCompletionRecovery() {
        let transport = Transport()
        transport.connect(desired: true)
        transport.complete()
        transport.controller.refreshEnabled()
        for _ in 0..<3 { transport.complete(false) }
        for _ in 0..<10 { transport.controller.refreshEnabled() }
        XCTAssertEqual(transport.requests.map(\.enabled), [true, true, true, true])
        XCTAssertEqual(transport.failures, [.attWriteFailed])
        XCTAssertTrue(transport.controller.recoveryRequested)
    }
}
