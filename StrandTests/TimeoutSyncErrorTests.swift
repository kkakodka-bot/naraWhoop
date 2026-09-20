import XCTest
import WhoopProtocol
@testable import Strand

/// #1466: a WHOOP 4.0 routinely ends a full, successful night on the idle timeout rather than
/// HISTORY_COMPLETE — a field log shows a session banking 17,205 rows and still exiting `reason=timeout`.
/// Before this, every such sync raised "Sync interrupted - the strap went quiet", reporting a success as a
/// failure. Twin of the Kotlin `TimeoutSyncErrorTest`.
final class TimeoutSyncErrorTests: XCTestCase {

    private let wentQuiet = "Sync interrupted - the strap went quiet. It will retry on the next sync."

    /// The regression: rows landed, so there is nothing to warn about.
    func testProductiveTimeoutRaisesNoBanner() {
        XCTAssertNil(BLEManager.timeoutSyncError(futureClockBanner: nil, bankedThisOffload: true))
    }

    /// The case the banner exists for: the session held the radio and handed over nothing.
    func testStalledTimeoutStillWarns() {
        XCTAssertEqual(BLEManager.timeoutSyncError(futureClockBanner: nil, bankedThisOffload: false),
                       wentQuiet)
    }

    /// Pins the predicate: banked iff at least one counter moved.
    ///
    /// What this does NOT do is stop a caller passing the wrong counter, which is the mistake that nearly
    /// shipped — Kotlin's neighbouring `bankedThisOffload` counts offload FRAMES, and a stall still
    /// receives them (three sessions in one field log ran 66–109s and took 42, 51 and 59 frames while
    /// banking zero rows). No test over this function can catch that, because a frame count is not one of
    /// its inputs. The guard is the signature plus named arguments at both call sites: `chunks:`, `rows:`
    /// and `deepPackets:` make a frame count visibly wrong where it is passed, not here.
    func testBankedIffSomeCounterMoved() {
        XCTAssertFalse(BLEManager.offloadBankedAnything(chunks: 0, rows: 0, deepPackets: 0))
        // ...and the productive night from the same log is banked on rows alone.
        XCTAssertTrue(BLEManager.offloadBankedAnything(chunks: 0, rows: 17_205, deepPackets: 0))
        XCTAssertTrue(BLEManager.offloadBankedAnything(chunks: 3, rows: 0, deepPackets: 0))
        XCTAssertTrue(BLEManager.offloadBankedAnything(chunks: 0, rows: 0, deepPackets: 5))
    }

    /// #324/#928: a future-dated strap times out BECAUSE of its clock, so that banner names the real cause
    /// and must outrank the generic one — including on a stalled session.
    func testFutureClockBannerOutranksTheGenericWarning() {
        XCTAssertEqual(BLEManager.timeoutSyncError(futureClockBanner: "clock is ahead",
                                                   bankedThisOffload: false), "clock is ahead")
    }

    /// ...and it must survive a PRODUCTIVE timeout too: rows landing does not make a bad clock fine, and
    /// those rows are exactly the ones being misfiled.
    func testFutureClockBannerSurvivesAProductiveTimeout() {
        XCTAssertEqual(BLEManager.timeoutSyncError(futureClockBanner: "clock is ahead",
                                                   bankedThisOffload: true), "clock is ahead")
    }

    @MainActor
    func testWhoop5StorageFailureSurvivesTimeoutWithoutClaimingASync() {
        let state = LiveState()
        let priorSync = Date().timeIntervalSince1970 - 15 * 3600
        state.lastSyncedAt = priorSync
        state.historySyncExperimental = true
        let manager = BLEManager(state: state, startCentral: false)

        manager.applyBackfillTimeoutOutcome(family: .whoop5, persistStalled: true,
                                            bankedThisOffload: false, futureClockBanner: nil)

        XCTAssertEqual(state.lastSyncError, "History sync stopped because records could not be saved on this device. The unacknowledged chunk remains on the strap. See Test Centre for the storage error.")
        XCTAssertFalse(state.historySyncExperimental)
        XCTAssertEqual(state.lastSyncedAt, priorSync)
    }

    @MainActor
    func testEarlierProgressDoesNotHideLaterStorageFailureForEitherFamily() {
        for family in [WhoopProtocol.DeviceFamily.whoop4, .whoop5] {
            let state = LiveState()
            let manager = BLEManager(state: state, startCentral: false)
            manager.applyBackfillTimeoutOutcome(family: family, persistStalled: true,
                                                bankedThisOffload: true, futureClockBanner: "clock is ahead")
            XCTAssertTrue(state.lastSyncError?.contains("could not be saved") == true)
            XCTAssertFalse(state.historySyncExperimental)
            XCTAssertNil(state.lastSyncedAt)
        }
    }

    @MainActor
    func testWhoop5StorageFailuresDoNotAccumulateAnExperimentalEmptyStreak() {
        let state = LiveState()
        let manager = BLEManager(state: state, startCentral: false)
        for _ in 0..<4 {
            manager.applyBackfillTimeoutOutcome(family: .whoop5, persistStalled: true,
                                                bankedThisOffload: false, futureClockBanner: nil)
            XCTAssertNotNil(state.lastSyncError)
            XCTAssertFalse(state.historySyncExperimental)
        }
        manager.applyBackfillTimeoutOutcome(family: .whoop5, persistStalled: false,
                                            bankedThisOffload: false, futureClockBanner: nil)
        XCTAssertNil(state.lastSyncError)
        XCTAssertFalse(state.historySyncExperimental)
    }

    @MainActor
    func testProductiveWhoop5TimeoutWithoutStorageFailureRemainsBannerFree() {
        let state = LiveState()
        state.historySyncExperimental = true
        let manager = BLEManager(state: state, startCentral: false)
        manager.applyBackfillTimeoutOutcome(family: .whoop5, persistStalled: false,
                                            bankedThisOffload: true, futureClockBanner: nil)
        XCTAssertNil(state.lastSyncError)
        XCTAssertFalse(state.historySyncExperimental)
        XCTAssertNil(state.lastSyncedAt)
    }
}
