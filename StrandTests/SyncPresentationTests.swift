import Foundation
import XCTest
@testable import Strand

final class SyncPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testPendingAndRestorationOverrideStaleDisconnectedHistoryFlags() {
        for phase in ["pendingConnection", "reconnecting", "restoring", "subscribing"] {
            let result = SyncPresentation.resolve(.init(connectionPhase: phase, connected: false,
                historyActive: true, confirmedChunks: 42, now: now))
            XCTAssertNotEqual(result.connection,.disconnected)
            XCTAssertNotEqual(result.connection,.catchingUp)
            XCTAssertNil(result.confirmedChunks)
        }
        XCTAssertEqual(SyncPresentation.resolve(.init(connectionPhase:"restoring",now:now)).connection,.restoring)
        XCTAssertEqual(SyncPresentation.resolve(.init(connectionPhase:"subscribing",now:now)).connection,.subscribing)
    }

    func testIntentionalDisconnectAndBluetoothLossCannotLookLikeActiveCatchup() {
        XCTAssertEqual(SyncPresentation.resolve(.init(connectionPhase:"intentionallyDisconnected",
            connected:true,historyActive:true,now:now)).connection,.intentionallyDisconnected)
        XCTAssertEqual(SyncPresentation.resolve(.init(connectionPhase:"bluetoothUnavailable",
            connected:true,historyActive:true,now:now)).connection,.bluetoothUnavailable)
    }

    func testHeatPausesNewCloudWorkWhileConfirmedBLEProgressContinues() {
        let result = SyncPresentation.resolve(.init(connectionPhase:"ready",connected:true,
            historyActive:true,confirmedChunks:123,cloud:.init(pendingJobs:2),budgetPause:.heat,now:now))
        XCTAssertEqual(result.connection,.catchingUp)
        XCTAssertEqual(result.confirmedChunks,123)
        XCTAssertEqual(result.cloud,.paused)
        XCTAssertEqual(result.cloudPause,.heat)
        XCTAssertNil(result.remainingHistorySeconds)
    }

    func testAdmittedUploadCanContinueWhileNewWorkIsPaused() {
        for reason in [SyncPresentation.Pause.heat,.lowPower,.network,.history,.cooldown] {
            let result = SyncPresentation.resolve(.init(cloud:.init(pendingJobs:1,transferringJobs:1),
                budgetPause:reason,now:now))
            XCTAssertEqual(result.cloud,.uploading)
            XCTAssertEqual(result.cloudPause,reason)
        }
    }

    func testTypedAuthenticationAndTerminalOutcomesRemainVisibleWithoutStagedJob() {
        for reason in [SyncPresentation.Pause.authentication,.terminal,.compatibleEncoding] {
            let result = SyncPresentation.resolve(.init(cloud:.init(pause:reason),budgetPause:.heat,now:now))
            XCTAssertEqual(result.cloud,.paused)
            XCTAssertEqual(result.cloudPause,reason)
        }
    }

    func testLocalSourceDebtAndSelectionsDoNotBecomeCloudSuccess() {
        let source = SyncPresentation.resolve(.init(cloud:.init(),sourceCloudDebt:true,now:now))
        let staged = SyncPresentation.resolve(.init(cloud:.init(pendingSelections:1),now:now))
        XCTAssertEqual(source.cloud,.pending)
        XCTAssertEqual(staged.cloud,.pending)
        XCTAssertNil(source.lastVerifiedReceipt)
        XCTAssertNil(staged.lastVerifiedReceipt)
        XCTAssertEqual(SyncPresentation.resolve(.init(cloud:.init(),sourceCloudDebt:false,now:now)).cloud,.idle)
        XCTAssertEqual(SyncPresentation.resolve(.init(now:now)).cloud,.unavailable)
    }

    func testRetryShowsScheduledPauseOnlyUntilItsPersistedDeadline() {
        let snapshot = SyncPresentation.CloudSnapshot(pendingJobs:1,retryAt:now.addingTimeInterval(30))
        XCTAssertEqual(SyncPresentation.resolve(.init(cloud:snapshot,now:now)).cloudPause,.retry)
        XCTAssertEqual(SyncPresentation.resolve(.init(cloud:snapshot,now:now.addingTimeInterval(30))).cloud,.pending)
    }

    func testAccountRetirementClearsProgressReceiptsAndEarlierStatus() {
        let result = SyncPresentation.resolve(.init(accountIsCurrent:false,connectionPhase:"ready",connected:true,
            historyActive:true,confirmedChunks:42,lastStrapSync:9_000,
            cloud:.init(pendingJobs:3,pause:.authentication,lastVerifiedReceipt:Date(timeIntervalSince1970:9_100)),now:now))
        XCTAssertEqual(result.connection,.unavailable)
        XCTAssertEqual(result.cloud,.unavailable)
        XCTAssertNil(result.lastStrapSync)
        XCTAssertNil(result.lastVerifiedReceipt)
        XCTAssertNil(result.cloudPause)
        XCTAssertNil(result.confirmedChunks)
    }

    func testDatesStayIndependentAndRejectUnknownInvalidOrFutureValues() {
        let result = SyncPresentation.resolve(.init(lastStrapSync:9_000,
            cloud:.init(lastVerifiedReceipt:Date(timeIntervalSince1970:8_000)),now:now))
        XCTAssertEqual(result.lastStrapSync,Date(timeIntervalSince1970:9_000))
        XCTAssertEqual(result.lastVerifiedReceipt,Date(timeIntervalSince1970:8_000))
        for value in [Double.nan, Double.infinity, -1, 0, 10_001] {
            let invalid = SyncPresentation.resolve(.init(lastStrapSync:value,
                cloud:.init(lastVerifiedReceipt:Date(timeIntervalSince1970:value)),now:now))
            XCTAssertNil(invalid.lastStrapSync)
            XCTAssertNil(invalid.lastVerifiedReceipt)
        }
    }

    func testHistoryPendingIsDistinctFromActiveProgressAndDisabledCloudFromNoDebt() {
        let result = SyncPresentation.resolve(.init(connectionPhase:"ready",connected:true,
            historyPending:true,confirmedChunks:50,cloudEnabled:false,cloud:.init(pendingJobs:1),now:now))
        XCTAssertEqual(result.connection,.historyPending)
        XCTAssertNil(result.confirmedChunks)
        XCTAssertNil(result.remainingHistorySeconds)
        XCTAssertEqual(result.cloud,.disabled)
    }

    func testExperimentalHistoryNoticeSurvivesUntilFirstCompletedOffloadAndClearsWithOwner() {
        var input = SyncPresentation.Input(connected:true,historyExperimental:true,now:now)
        XCTAssertTrue(SyncPresentation.resolve(input).showsExperimentalHistoryNotice)
        input.historyActive = true
        XCTAssertTrue(SyncPresentation.resolve(input).showsExperimentalHistoryNotice)
        input.accountIsCurrent = false
        XCTAssertFalse(SyncPresentation.resolve(input).showsExperimentalHistoryNotice)
        input.accountIsCurrent = true
        input.connected = false
        XCTAssertFalse(SyncPresentation.resolve(input).showsExperimentalHistoryNotice)
        input.connected = true
        input.lastStrapSync = 9_000
        XCTAssertFalse(SyncPresentation.resolve(input).showsExperimentalHistoryNotice)
    }

    func testUnknownSourceDebtUnderHistoryPressureDoesNotClaimAnEmptyQueue() {
        var input = SyncPresentation.Input(connectionPhase:"ready",connected:true,historyActive:true,
            cloud:.init(),budgetPause:.history,now:now)
        XCTAssertEqual(SyncPresentation.resolve(input).cloud,.unavailable)
        // An admitted metadata read after pressure/cooldown establishes the missing source fact.
        input.historyActive = false
        input.budgetPause = nil
        input.sourceCloudDebt = true
        XCTAssertEqual(SyncPresentation.resolve(input).cloud,.pending)
        input.sourceCloudDebt = false
        XCTAssertEqual(SyncPresentation.resolve(input).cloud,.idle)
        input.sourceCloudDebt = nil
        input.cloud?.pendingJobs = 1
        XCTAssertEqual(SyncPresentation.resolve(input).cloud,.pending)
    }

    func testQueuePressurePausesPreparationButDoesNotClaimTransfersAreBlocked() {
        let result = SyncPresentation.resolve(.init(cloud:.init(pendingJobs:128),budgetPause:.queuedCloud,now:now))
        XCTAssertEqual(result.cloud,.pending)
        XCTAssertEqual(result.cloudPause,.queuedCloud)
    }
}
