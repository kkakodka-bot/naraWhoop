import XCTest
import WhoopStore
@testable import Strand

final class ServerScoreSleepModelTests: XCTestCase {
    func testOwnedSleepCapabilityWithdrawalReturnsUnavailableWithoutLocalFallback() throws {
        let day = "2026-09-18"
        let local = try XCTUnwrap(SleepModel.build(inputs()))
        for capabilities in [[], ["hrv_rmssd_ms"], ["sleep_sessions"]] {
            let body: [String: Any] = ["schemaVersion": 2, "day": day, "timezone": "UTC",
                "userId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                "algorithmVersion": "fixture", "inputRevision": 1, "resultRevision": 2,
                "computedAt": "2026-09-18T16:00:00Z", "status": "partial", "coverage": [:],
                "capabilities": capabilities, "sleep": [["id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
                    "start_at": "2026-09-18T06:00:00Z", "end_at": "2026-09-18T14:00:00Z", "is_nap": false, "stages": []]]]
            let snapshot = try XCTUnwrap(ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: body), requestedDay: day).snapshot)
            let view = ServerScoreViewState(generation: UUID(), revision: 1, currentDay: day, timezone: "UTC",
                configured: true, authenticated: true, capabilities: [.sleepSessions], activated: [.sleepSessions],
                days: [day: .init(snapshot: snapshot, phase: .offline, fetchedAt: nil, cached: true,
                    pending: false, requestedInputRevision: nil, archiveStatus: nil)])
            let result = ServerScoreSleepPresentation.model(day: day, state: view, local: local)
            XCTAssertEqual(result != nil, capabilities.contains("sleep_sessions"))
        }
    }

    func testMainNightWarningsUseCanonicalServerSelectionAndExcludeNapEvidence() throws {
        let midnight = Int(try XCTUnwrap(ServerScoreDate.parse("2026-09-18T00:00:00Z")).timeIntervalSince1970)
        func block(_ hour: Int, coveredHours: Int, sparse: Bool) throws -> CachedSleepSession {
            let start = midnight + hour * 3600
            let stages = try JSONSerialization.data(withJSONObject: [["start": start, "end": start + coveredHours * 3600, "stage": "light"]])
            return CachedSleepSession(startTs: start, endTs: start + 4 * 3600, efficiency: nil, restingHr: nil,
                avgHrv: nil, stagesJSON: String(decoding: stages, as: UTF8.self), stagingSparse: sparse)
        }
        let main = try block(12, coveredHours: 2, sparse: false)
        let nap = try block(0, coveredHours: 4, sparse: true)
        var night = Night(session: main, stages: .init(awake: 0, light: 120, deep: 0, rem: 0), sourceBlocks: [nap, main])
        night.serverMainGroupStarts = [main.startTs]
        XCTAssertEqual(try XCTUnwrap(night.stageCoverageFraction), 0.5, accuracy: 1e-12)
        XCTAssertFalse(night.hasSparseMainStaging)
        night.serverMainGroupStarts = []
        XCTAssertNil(night.stageCoverageFraction)
        XCTAssertFalse(night.hasSparseMainStaging)
        night.serverMainGroupStarts = [nap.startTs]
        XCTAssertEqual(night.stageCoverageFraction, 1)
        XCTAssertTrue(night.hasSparseMainStaging)
    }

    private func inputs() throws -> SleepModelInputs {
        let start = Int(try XCTUnwrap(ServerScoreDate.parse("2026-09-18T06:00:00Z")).timeIntervalSince1970)
        let end = start + 8 * 3600
        let segments: [[String: Any]] = [["start": start, "end": start + 3600, "stage": "deep"],
                                        ["start": start + 3600, "end": end, "stage": "light"]]
        let stages = String(decoding: try JSONSerialization.data(withJSONObject: segments), as: UTF8.self)
        let session = CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9,
                                        restingHr: 55, avgHrv: 40, stagesJSON: stages)
        let day = DailyMetric(day: "2026-09-18", totalSleepMin: 480, efficiency: 0.9,
                              deepMin: 60, remMin: 90, lightMin: 330, disturbances: nil,
                              restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
                              exerciseCount: nil, respRateBpm: 16)
        return SleepModelInputs(days: [day], sleeps: [session], allSessions: [session],
                                importedSleep: [:], habitualMidsleepSec: nil, motionByStart: [:])
    }
    private func state(_ owned: Set<ServerScoreMetric>) -> ServerScoreViewState {
        .init(generation: UUID(), revision: 1, currentDay: "2026-09-18", timezone: "UTC",
              configured: true, authenticated: true, capabilities: owned, activated: owned, days: [:])
    }

    func testPartialOwnershipSuppressesOnlyOwnedSleepDerivations() throws {
        let input = try inputs()
        let local = try XCTUnwrap(SleepModel.build(input))
        let owned = try XCTUnwrap(SleepModel.build(input, compute: .init(state: state([.sleepDebt, .respiration]))))
        XCTAssertFalse(local.sleepDebt.series.isEmpty)
        XCTAssertTrue(owned.sleepDebt.series.isEmpty)
        XCTAssertTrue(owned.respiratory.series.isEmpty)
        XCTAssertTrue(owned.debtLedgerUnavailable)
        XCTAssertEqual(owned.efficiency.series, local.efficiency.series)
        XCTAssertEqual(owned.performance.series, local.performance.series)
        XCTAssertEqual(owned.typicalTotalMin, local.typicalTotalMin)
        XCTAssertEqual(owned.intervals.count, local.intervals.count)
    }

    func testOwnedDurationDoesNotRebuildLocalTrendOrBaseline() throws {
        let input = try inputs()
        let view = state([.sleepTotal])
        let local = try XCTUnwrap(SleepModel.build(input))
        XCTAssertNotNil(local.typicalTotalMin)
        let limited = try XCTUnwrap(SleepModel.build(input, compute: .init(state: view)))
        XCTAssertNil(limited.typicalTotalMin)
        XCTAssertTrue(limited.trendPoints.isEmpty)
        let displayed = try XCTUnwrap(ServerScoreSleepPresentation.model(day: view.currentDay, state: view, local: local))
        XCTAssertNil(displayed.typicalTotalMin)
        XCTAssertTrue(displayed.trendPoints.isEmpty)
        XCTAssertEqual(displayed.efficiency.series, local.efficiency.series)
    }

    func testServerSleepDetailsReplaceExistingLedgerAndTypicalsWithoutLocalFallback() throws {
        let day = "2026-09-18"
        var object: [String: Any] = ["schemaVersion": 2, "day": day, "timezone": "UTC",
            "userId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "algorithmVersion": "fixture", "inputRevision": 1, "resultRevision": 2,
            "computedAt": "2026-09-18T12:00:00Z", "status": "partial", "coverage": [:], "sleep": [],
            "capabilities": ["sleep_debt_min", "sleep_total_min", "sleep_deep_min", "sleep_ledger", "sleep_typicals"],
            "details": ["sleep_ledger": ["needMin": 480, "balanceMin": -33, "nightCount": 1, "descriptiveNeedMin": 450,
                                         "nights": [["day": day, "sleptMin": 420, "deltaMin": -60]]],
                        "sleep_typicals": ["method": "strictly_prior_observed_nights", "asleepMin": 450, "deepMin": NSNull()]]]
        let local = try XCTUnwrap(SleepModel.build(inputs()))
        func displayed() throws -> SleepModel {
            let response = try ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: object), requestedDay: day)
            let snapshot = try XCTUnwrap(response.snapshot)
            let view = ServerScoreViewState(generation: UUID(), revision: 1, currentDay: day, timezone: "UTC",
                configured: true, authenticated: true, capabilities: snapshot.supported,
                activated: [.sleepDebt, .sleepTotal, .sleepDeep],
                days: [day: .init(snapshot: snapshot, phase: .partial, fetchedAt: Date(), cached: false,
                                 pending: false, requestedInputRevision: nil, archiveStatus: nil)])
            return try XCTUnwrap(ServerScoreSleepPresentation.model(day: day, state: view, local: local))
        }
        let server = try displayed()
        XCTAssertEqual(server.sleepDebtLedger.balanceMin, -33)
        XCTAssertEqual(server.sleepDebtLedger.nights.first?.deltaMin, -60)
        XCTAssertFalse(server.debtLedgerUnavailable)
        XCTAssertEqual(server.typicalTotalMin, 450)
        XCTAssertNil(server.typicalDeepMin)
        XCTAssertEqual(server.typicalRemMin, local.typicalRemMin)
        object["details"] = NSNull()
        let missing = try displayed()
        XCTAssertTrue(missing.debtLedgerUnavailable)
        XCTAssertTrue(missing.sleepDebtLedger.nights.isEmpty)
        XCTAssertNil(missing.typicalTotalMin)
        XCTAssertNil(missing.typicalDeepMin)
    }

    @MainActor
    func testLocalInputCaptureIgnoresAuthoritativeEmptyPresentationAndRetainsValueSnapshot() throws {
        let input = try inputs()
        let repo = Repository(deviceId: "sleep-input-fixture", presentationAllowed: false)
        repo.days = input.days
        repo.sleeps = input.sleeps
        let before = SleepModelInputs.captureLocal(from: repo)
        repo.applyServerScores(state([.sleepTotal, .sleepSessions, .sleepEfficiency, .respiration]))
        XCTAssertNil(repo.days.first?.totalSleepMin)
        XCTAssertTrue(repo.sleeps.isEmpty)

        let captured = SleepModelInputs.captureLocal(from: repo)
        XCTAssertEqual(captured.days, before.days)
        XCTAssertEqual(captured.sleeps, before.sleeps)
        let rebuilt = try XCTUnwrap(SleepModel.build(captured))
        let original = try XCTUnwrap(SleepModel.build(before))
        XCTAssertEqual(rebuilt.performance.series, original.performance.series)
        XCTAssertEqual(rebuilt.efficiency.series, original.efficiency.series)

        repo.shutdownForAccountChange()
        let afterRetirement = SleepModelInputs.captureLocal(from: repo)
        XCTAssertTrue(afterRetirement.days.isEmpty)
        XCTAssertTrue(afterRetirement.sleeps.isEmpty)
        XCTAssertEqual(captured.days, input.days, "A captured value does not track later repository mutations")
        XCTAssertEqual(captured.withLocalSessions(input.allSessions, habitualMidsleepSec: nil,
                                                 motionByStart: [:]).days, input.days)
    }
}
