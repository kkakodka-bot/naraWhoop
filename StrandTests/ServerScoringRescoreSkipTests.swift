import XCTest
@testable import Strand

/// Server ownership suppresses individual migrated metrics; the local pass still owes unmigrated fields.
@MainActor
final class ServerScoringRescoreSkipTests: XCTestCase {

    private var savedServerScoring: Any?
    private var savedOwed: Any?
    private var savedToken: Any?

    override func setUp() {
        super.setUp()
        savedServerScoring = UserDefaults.standard.object(forKey: ServerScoringSettings.defaultsKey)
        savedOwed = UserDefaults.standard.object(forKey: RescoreBackgroundScheduler.owedKey)
        savedToken = UserDefaults.standard.object(forKey: RescoreBackgroundScheduler.owedTokenKey)
        UserDefaults.standard.removeObject(forKey: ServerScoringSettings.defaultsKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.owedKey)
        UserDefaults.standard.removeObject(forKey: RescoreBackgroundScheduler.owedTokenKey)
    }

    override func tearDown() {
        restore(savedServerScoring, ServerScoringSettings.defaultsKey)
        restore(savedOwed, RescoreBackgroundScheduler.owedKey)
        restore(savedToken, RescoreBackgroundScheduler.owedTokenKey)
        super.tearDown()
    }

    private func restore(_ value: Any?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testDefaultOnWhenUnset() {
        XCTAssertTrue(ServerScoringSettings.isEnabled)
    }

    func testPreservesSyncCoupledRescoreForUnmigratedFieldsWhenFlagOn() {
        ServerScoringSettings.setEnabled(true)
        XCTAssertFalse(ServerScoringSettings.skipsSyncCoupledRescore)
    }

    func testRunsSyncCoupledRescoreWhenFlagOff() {
        ServerScoringSettings.setEnabled(false)
        XCTAssertFalse(ServerScoringSettings.skipsSyncCoupledRescore)
    }

    func testServerScoringFlagCannotSettleLocalRescoreDebt() {
        ServerScoringSettings.setEnabled(true)
        let token = RescoreBackgroundScheduler.markRescoreOwed()
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        ServerScoringSettings.settleSkippedLocalRescoreDebt()
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        XCTAssertEqual(RescoreBackgroundScheduler.currentOwedToken, token)
    }

    func testSettleSkippedLocalRescoreDebtNoOpWhenFlagOff() {
        ServerScoringSettings.setEnabled(false)
        let token = RescoreBackgroundScheduler.markRescoreOwed()
        ServerScoringSettings.settleSkippedLocalRescoreDebt()
        XCTAssertTrue(RescoreBackgroundScheduler.isRescoreOwed)
        XCTAssertEqual(RescoreBackgroundScheduler.currentOwedToken, token)
    }

    func testPushIntervalTightensWhenServerScoringOn() {
        XCTAssertEqual(CloudPushPeriodicScheduler.effectiveInterval(serverScoringEnabled: true), 45, accuracy: 0.001)
        XCTAssertEqual(CloudPushPeriodicScheduler.effectiveInterval(serverScoringEnabled: false),
                       CloudPushPeriodicScheduler.defaultInterval, accuracy: 0.001)
    }
}
