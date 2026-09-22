import XCTest
import CoreBluetooth
@testable import Strand

/// The WHOOP reconnect policy after an involuntary drop or a failed connect — twin of
/// `OuraReconnectPolicyTests` (#1413).
///
/// The original `DispatchQueue.main.asyncAfter` backoff does not fire in a suspended app and, after
/// `didFailToConnect`, left NOTHING outstanding with CoreBluetooth — so an overnight drop stayed dead for
/// hours (measured 10h46m50s on a 5/MG). The first fix handed off to a standing `central.connect`, but only
/// after three consecutive failures, which made it unreachable in the case it was written for: a drop while
/// suspended wakes the app just long enough to arm a 3-second timer that then never fires, so the counter
/// never reaches three and nothing is outstanding meanwhile. The handoff now happens on the FIRST drop.
///
/// ⚠️ These test the POLICY, not the plumbing. Whether a standing `central.connect` really survives
/// suspension on a real phone is a hardware question and is owed a strap night.
final class BLEManagerReconnectPolicyTests: XCTestCase {

    /// THE REGRESSION TEST. The first drop must hand off to CoreBluetooth immediately. Anything else is a
    /// timer, and a timer is what the suspended app swallows — this is the state the night died in.
    func testFirstDropHandsOffImmediately() {
        XCTAssertEqual(BLEManager.reconnectStep(secondsSinceStandingConnect: nil), .standingConnect)
    }

    /// A standing connect that stayed outstanding a while before failing (the `Failed to encrypt the
    /// connection` shape this strap produces after 7–11s) is re-issued IMMEDIATELY, so a suspension can never
    /// catch us holding nothing.
    func testSlowStandingFailureReissuesImmediately() {
        XCTAssertEqual(BLEManager.reconnectStep(secondsSinceStandingConnect: 8), .standingConnect)
    }

    func testInstantStandingFailureKeepsTheRetryFloor() {
        XCTAssertEqual(BLEManager.reconnectStep(secondsSinceStandingConnect: 1),
                       .standingConnectAfter(delay: BLEManager.standingConnectRetryFloor - 1))
    }

    /// The boundary itself: at exactly the fast-failure threshold the connect stayed up long enough to count
    /// as a real attempt, so it re-issues rather than waiting.
    func testAtTheFastFailureBoundaryItReissues() {
        XCTAssertEqual(BLEManager.reconnectStep(
            secondsSinceStandingConnect: BLEManager.standingConnectFastFailureS), .standingConnect)
    }

    /// No run loop or timer is advanced. Every plan must hand a request to the transport in this call.
    func testEveryReconnectHandsOffBeforeTheCallbackReturns() {
        for since in [nil, -29, 0, 0.5, 1.9, 2, 8, 60, 3600] as [TimeInterval?] {
            let step = BLEManager.reconnectStep(secondsSinceStandingConnect: since)
            var submitted = 0
            var systemDelay: Double?
            step.handOff { options in
                submitted += 1
                systemDelay = (options?[CBConnectPeripheralOptionStartDelayKey] as? NSNumber)?.doubleValue
            }
            XCTAssertEqual(submitted, 1, "since=\(String(describing: since))")
            XCTAssertEqual(systemDelay ?? 0, step.startDelay)
            XCTAssertLessThanOrEqual(systemDelay ?? 0, BLEManager.standingConnectRetryFloor)
        }
    }

    func testFastFailureUsesCoreBluetoothDelayInsteadOfWaitingForAnAppTimer() {
        var options: [String: Any]?
        BLEManager.reconnectStep(secondsSinceStandingConnect: 1).handOff { options = $0 }
        XCTAssertEqual((options?[CBConnectPeripheralOptionStartDelayKey] as? NSNumber)?.doubleValue, 29)
        XCTAssertEqual(options?.count, 1)
    }

    func testPostBondTimeoutTripParksAfterDisconnectedStateIsPublished() throws {
        var detector = PostBondTimeoutLoopDetector()
        XCTAssertFalse(detector.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true))
        let justTripped = detector.connectionEnded(wasBonded: true, secondsSinceBond: 1, timedOut: true)
        XCTAssertTrue(justTripped)
        XCTAssertNil(BLEManager.pausedStandingConnectDelay(
            pausedForBondLoop: true, connected: true, intentionalDisconnect: false,
            secondsSincePauseTripped: nil))

        let delay = try XCTUnwrap(BLEManager.pausedStandingConnectDelay(
            pausedForBondLoop: true, connected: false, intentionalDisconnect: false,
            secondsSincePauseTripped: justTripped ? nil : 0))
        var requests = 0
        BLEManager.ReconnectStep.standingConnectAfter(delay: delay).handOff { options in
            requests += 1
            XCTAssertNil(options)
        }
        XCTAssertEqual(requests, 1)
    }

    func testConsumedPausedAttemptsStayPendingWithoutSkippingTheirCooldown() throws {
        let epoch = Date(timeIntervalSince1970: 0)
        var scheduledAttemptAt = epoch
        var requests = 0
        // Initial parked attempt fails at t=1; the retry starts at 600 and fails at 601.
        for failureTime in [1.0, 601.0] {
            let now = epoch.addingTimeInterval(failureTime)
            let delay = try XCTUnwrap(BLEManager.pausedStandingConnectDelay(
                pausedForBondLoop: true, connected: false, intentionalDisconnect: false,
                secondsSincePauseTripped: now.timeIntervalSince(scheduledAttemptAt)))
            BLEManager.ReconnectStep.standingConnectAfter(delay: delay).handOff { options in
                requests += 1
                XCTAssertEqual((options?[CBConnectPeripheralOptionStartDelayKey] as? NSNumber)?.doubleValue, 599)
            }
            scheduledAttemptAt = now.addingTimeInterval(delay)
        }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(scheduledAttemptAt.timeIntervalSince1970, 1200)
    }

    func testPausedRetryNeverOverridesUserTeardownOrAnExistingLink() {
        for elapsed in [nil, 0, 599, 600, 3600] as [TimeInterval?] {
            XCTAssertNil(BLEManager.pausedStandingConnectDelay(
                pausedForBondLoop: true, connected: false, intentionalDisconnect: true,
                secondsSincePauseTripped: elapsed))
            XCTAssertNil(BLEManager.pausedStandingConnectDelay(
                pausedForBondLoop: true, connected: true, intentionalDisconnect: false,
                secondsSincePauseTripped: elapsed))
            XCTAssertNil(BLEManager.pausedStandingConnectDelay(
                pausedForBondLoop: false, connected: false, intentionalDisconnect: false,
                secondsSincePauseTripped: elapsed))
        }
    }

    func testFailedWhoop5NotificationCanRecoverOnAStillConnectedLink() {
        XCTAssertTrue(BLEManager.shouldRepairWhoop5Notification(
            isCurrentConnection: true, encryptedBond: true, isNotifying: false,
            restoring: false, sinceLastAttempt: .seconds(30)))
    }

    func testWhoop5NotificationRepairCannotUseUnbondedOrStaleConnection() {
        for current in [false, true] {
            for bonded in [false, true] where !current || !bonded {
                XCTAssertFalse(BLEManager.shouldRepairWhoop5Notification(
                    isCurrentConnection: current, encryptedBond: bonded, isNotifying: false,
                    restoring: true, sinceLastAttempt: nil))
            }
        }
    }

    func testWhoop5NotificationRepairIsRateLimitedAcrossReconciliationTriggers() {
        XCTAssertTrue(BLEManager.shouldRepairWhoop5Notification(
            isCurrentConnection: true, encryptedBond: true, isNotifying: false,
            restoring: false, sinceLastAttempt: nil))
        for elapsed in [Duration.zero, .seconds(1), .seconds(29)] {
            XCTAssertFalse(BLEManager.shouldRepairWhoop5Notification(
                isCurrentConnection: true, encryptedBond: true, isNotifying: false,
                restoring: false, sinceLastAttempt: elapsed))
        }
    }

    func testActiveWhoop5NotificationsAreUntouchedExceptForRestoration() {
        XCTAssertFalse(BLEManager.shouldRepairWhoop5Notification(
            isCurrentConnection: true, encryptedBond: true, isNotifying: true,
            restoring: false, sinceLastAttempt: .seconds(300)))
        XCTAssertTrue(BLEManager.shouldRepairWhoop5Notification(
            isCurrentConnection: true, encryptedBond: true, isNotifying: true,
            restoring: true, sinceLastAttempt: nil))
        XCTAssertFalse(BLEManager.shouldRepairWhoop5Notification(
            isCurrentConnection: true, encryptedBond: true, isNotifying: true,
            restoring: true, sinceLastAttempt: .seconds(1)))
    }
}
