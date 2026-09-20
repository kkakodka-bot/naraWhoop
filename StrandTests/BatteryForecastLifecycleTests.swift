import XCTest
import StrandAnalytics
@testable import Strand

@MainActor
final class BatteryForecastLifecycleTests: XCTestCase {
    private let end = 1_700_000_000

    func testMGModelIsConfiguredBeforeAnyConnectionCallback() {
        let key = "selectedWhoopModel"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        for model in WhoopModel.allCases {
            UserDefaults.standard.set(model.rawValue, forKey: key)
            let live = LiveState()
            let manager = BLEManager(state: live, startCentral: false)
            let expected = model == .whoop5mg ? 288.0 : 108.0
            XCTAssertEqual(live.batteryRatedHours, expected)
            withExtendedLifetime(manager) {}
        }
    }

    func testReconnectRetainsDischargeButWithdrawsCurrentLinkEvidence() {
        let live = LiveState()
        live.selectBatteryDevice("strap-a")
        live.batteryRatedHours = 288
        live.setBattery(40)
        let now = live.batterySamples.last!.ts
        live.seedBatterySamples([(now - 60 * 3600, 64), (now - 3600, 40.4)], now: now)
        let before = live.batteryEstimate
        XCTAssertEqual(before?.source, .measured)
        live.clearBiometrics()
        XCTAssertEqual(live.batteryEstimate, before)
        XCTAssertNil(live.freshBatterySoc)
        XCTAssertEqual(live.batteryPct, 40)
    }

    func testRelaunchAndDelayedSeedKeepLivePercentageAsForecastAnchor() {
        let live = LiveState()
        live.batteryRatedHours = 288
        live.batteryPct = 40
        // Seed's latest percentage is higher than the visible gauge. It must only supply a rate.
        live.seedBatterySamples([(end - 60 * 3600, 84), (end, 60)], now: end)
        let estimate = live.batteryEstimate!
        XCTAssertEqual(estimate.currentSoc, 40)
        XCTAssertEqual(estimate.remainingHours, 100, accuracy: 0.0001)
        live.seedBatterySamples([(end - 60 * 3600, 84), (end, 60)], now: end)
        XCTAssertEqual(live.batteryEstimate, estimate)
    }

    func testDeviceSwitchClearsContextAndFencesLateSeedsAcrossAToBToA() {
        let live = LiveState()
        live.selectBatteryDevice("a")
        live.bankBatterySample(80, now: end)
        let generation = live.batteryHistoryGeneration
        live.selectBatteryDevice("a")
        XCTAssertEqual(live.batterySamples.count, 1)
        XCTAssertEqual(live.batteryHistoryGeneration, generation)
        live.selectBatteryDevice("b")
        XCTAssertTrue(live.batterySamples.isEmpty)
        XCTAssertNil(live.batteryPct)
        live.selectBatteryDevice("a")
        XCTAssertNotEqual(live.batteryHistoryGeneration, generation)
    }

    func testSeedRejectsFutureExpiredInvalidAndDuplicateRows() {
        let live = LiveState()
        live.seedBatterySamples([(end, 40), (end, 40), (end + 1, 90),
                                 (end - LiveState.batteryHistorySeconds - 1, 80),
                                 (end - 1, .nan), (end - 2, 101), (end - 3, -1)], now: end)
        XCTAssertEqual(live.batterySamples.count, 1)
        XCTAssertEqual(live.batterySamples.first?.soc, 40)
        XCTAssertNil(live.freshBatterySoc)
        live.setBattery(.infinity)
        XCTAssertNil(live.batteryPct)
    }

    func testFullMGCycleFitsInHistoryAcrossReconnect() {
        let live = LiveState()
        let count = 12 * 24 * 6
        var samples: [(ts: Int, soc: Double)] = []
        for index in 0..<count {
            let timestamp = end - (count - 1 - index) * 600
            let percentage = 100.0 - Double(index) / Double(count) * 90.0
            samples.append((ts: timestamp, soc: percentage))
        }
        live.seedBatterySamples(samples, now: end)
        XCTAssertEqual(live.batterySamples.count, count)
        let before = live.batteryEstimate
        live.clearBiometrics()
        XCTAssertEqual(live.batteryEstimate, before)
    }
}
