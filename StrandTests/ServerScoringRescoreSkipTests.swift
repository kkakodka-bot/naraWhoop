import XCTest
import WhoopStore
@testable import Strand

/// Partial hosted ownership must not retire a daily kernel whose output closure is unported.
@MainActor
final class ServerScoringRescoreSkipTests: XCTestCase {

    private var savedServerScoring: Any?
    private var savedOwed: Any?
    private var savedToken: Any?
    private var savedOverlayLive: Bool = false

    override func setUp() {
        super.setUp()
        savedServerScoring = UserDefaults.standard.object(forKey: ServerScoringSettings.defaultsKey)
        savedOwed = UserDefaults.standard.object(forKey: RescoreBackgroundScheduler.owedKey)
        savedToken = UserDefaults.standard.object(forKey: RescoreBackgroundScheduler.owedTokenKey)
        savedOverlayLive = CloudScoreIdentity.overlayLive
        UserDefaults.standard.removeObject(forKey: ServerScoringSettings.defaultsKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.owedKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.owedTokenKey)
        CloudScoreIdentity.markOverlayLive(false)
    }

    override func tearDown() {
        restore(savedServerScoring, ServerScoringSettings.defaultsKey)
        restore(savedOwed, RescoreBackgroundScheduler.owedKey)
        restore(savedToken, RescoreBackgroundScheduler.owedTokenKey)
        CloudScoreIdentity.markOverlayLive(savedOverlayLive)
        super.tearDown()
    }

    private func restore(_ value: Any?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testDefaultOnWhenUnset() {
        XCTAssertTrue(ServerScoringSettings.isEnabled)
    }

    func testLegacyGlobalOverlayCannotSuppressUnportedDailyOutputs() {
        ServerScoringSettings.setEnabled(true)
        CloudScoreIdentity.markOverlayLive(false)
        XCTAssertFalse(ServerScoringSettings.skipsSyncCoupledRescore)
        CloudScoreIdentity.markOverlayLive(true)
        XCTAssertFalse(ServerScoringSettings.skipsSyncCoupledRescore)
        CloudScoreIdentity.markOverlayLive(false)
    }

    func testRunsSyncCoupledRescoreWhenFlagOff() {
        ServerScoringSettings.setEnabled(false)
        XCTAssertFalse(ServerScoringSettings.skipsSyncCoupledRescore)
    }

    func testPartialOverlayCannotSettleUnportedLocalRescoreDebt() {
        ServerScoringSettings.setEnabled(true)
        CloudScoreIdentity.markOverlayLive(true)
        let token = RescoreBackgroundScheduler.markRescoreOwed()
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        ServerScoringSettings.settleSkippedLocalRescoreDebt()
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        XCTAssertEqual(RescoreBackgroundScheduler.currentOwedToken, token)
    }

    func testShadowServerOverlayPreservesLocalRescoreDebt() {
        ServerScoringSettings.setEnabled(true)
        CloudScoreIdentity.markOverlayLive(false)
        _ = RescoreBackgroundScheduler.markRescoreOwed()
        ServerScoringSettings.settleSkippedLocalRescoreDebt()
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
    }

    func testSettleSkippedLocalRescoreDebtNoOpWhenFlagOff() {
        ServerScoringSettings.setEnabled(false)
        let token = RescoreBackgroundScheduler.markRescoreOwed()
        ServerScoringSettings.settleSkippedLocalRescoreDebt()
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        XCTAssertEqual(RescoreBackgroundScheduler.currentOwedToken, token)
    }

    func testPushIntervalTightensWhenServerScoringOn() {
        XCTAssertEqual(CloudPushPeriodicScheduler.effectiveInterval(serverScoringEnabled: true),
                       CloudPushPeriodicScheduler.defaultInterval, accuracy: 0.001)
        XCTAssertEqual(CloudPushPeriodicScheduler.effectiveInterval(serverScoringEnabled: false),
                       CloudPushPeriodicScheduler.defaultInterval, accuracy: 0.001)
    }

    private func snapshot(stale: Bool = false, featureStatus: String = "available") throws -> ServerScoreDayCache {
        let data = try JSONSerialization.data(withJSONObject: ["server_scoring": [
            "schema_version": 2, "user_id": "11111111-1111-1111-1111-111111111111",
            "day": "2026-09-18", "algorithm_version": "per_feature", "stale": stale,
            "features": ["hrv": ["status": featureStatus, "device_id": "device",
                                  "algorithm_version": "frwhoop-server-1", "input_revision": 1, "required_revision": 1]],
            "daily": ["hrv_rmssd_ms": 42], "nights": []
        ]])
        return try ServerScoreCacheCodec.parseSnapshot(data, day: "2026-09-18",
            ownerId: "11111111-1111-1111-1111-111111111111")
    }

    func testStaleServerSnapshotIsNotLive() throws {
        XCTAssertFalse(CloudScoreIdentity.overlayIsLive(try snapshot(stale: true)))
        XCTAssertFalse(CloudScoreIdentity.overlayIsLive(try snapshot(featureStatus: "stale")))
        XCTAssertTrue(CloudScoreIdentity.overlayIsLive(try snapshot()))
    }

    func testHostedModeDoesNotResurrectLocalVitalWhenServerValueIsUnavailable() throws {
        let cache = try snapshot()
        for overlay in [Optional<ServerScoreDayCache>.none, cache] {
            let selection = ServerVitalSelection.resolve(.restingHR, serverEnabled: true,
                selectedDay: "2026-09-18", overlay: overlay, localValue: 51)
            XCTAssertNil(selection.value)
            XCTAssertTrue(selection.fromServer)
        }
    }

    func testSelectionRetainsStaleProvenanceForActualServerValue() throws {
        let selection = ServerVitalSelection.resolve(.hrv, serverEnabled: true,
            selectedDay: "2026-09-18", overlay: try snapshot(stale: true), localValue: 51)
        XCTAssertEqual(selection.value, 42)
        XCTAssertTrue(selection.fromServer)
        XCTAssertTrue(selection.stale)
        XCTAssertEqual(selection.day, "2026-09-18")
        XCTAssertEqual(selection.status, "available")
    }
}
