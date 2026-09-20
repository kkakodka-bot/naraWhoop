import XCTest
#if !SERVER_SCORE_NATIVE_TESTS
@testable import Strand
#endif

final class ServerScoreSleepDetailsTests: XCTestCase {
    private let day = "2026-09-15"
    private let sleepID = "40000000-0000-4000-8000-000000000001"
    private var ledger: [String: Any] {
        ["needMin": 480, "balanceMin": -33, "nightCount": 1, "descriptiveNeedMin": 450,
         "habitualMidsleepSec": NSNull(), "restDurationConsistency": NSNull(),
         "nights": [["day": day, "sleptMin": 420, "deltaMin": -60]]]
    }
    private var typicals: [String: Any] {
        ["method": "strictly_prior_observed_nights", "asleepMin": 450, "deepMin": 60,
         "remMin": NSNull(), "lightMin": 300]
    }
    private func snapshot(_ updates: [String: Any] = [:]) throws -> ServerScoreSnapshot {
        var object: [String: Any] = ["schemaVersion": 2,
            "userId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "day": day, "timezone": "UTC",
            "algorithmVersion": "fixture", "inputRevision": 1, "resultRevision": 2,
            "computedAt": "2026-09-15T12:00:00Z", "status": "partial", "coverage": [:], "sleep": [],
            "capabilities": ["sleep_debt_min", "sleep_total_min", "sleep_rem_min", "sleep_ledger", "sleep_typicals"],
            "details": ["sleep_ledger": ledger, "sleep_typicals": typicals]]
        object.merge(updates) { _, new in new }
        let response = try ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: object), requestedDay: day)
        return try XCTUnwrap(response.snapshot)
    }
    private func state(_ snapshot: ServerScoreSnapshot, active: Set<ServerScoreMetric>) -> ServerScoreViewState {
        .init(generation: UUID(), revision: 1, currentDay: day, timezone: "UTC", configured: true,
              authenticated: true, capabilities: snapshot.supported, activated: active,
              days: [day: .init(snapshot: snapshot, phase: .partial, fetchedAt: Date(), cached: false,
                               pending: false, requestedInputRevision: nil, archiveStatus: nil)])
    }

    func testSleepDetailsRoundTripSignedLedgerAndNullableTypicals() throws {
        let value = try snapshot()
        XCTAssertEqual(value.details?.sleepLedger?.balanceMin, -33)
        XCTAssertEqual(value.details?.sleepLedger?.nights.first?.deltaMin, -60)
        XCTAssertNil(value.details?.sleepTypicals?.remMin)
        XCTAssertEqual(try ServerScoreResponse.decode(value.encoded(), requestedDay: day).snapshot, value)
    }

    func testDetailsRequireParentOwnershipAndExplicitResultCapability() throws {
        let value = try snapshot()
        XCTAssertNil(ServerScoreDisplay.sleepLedger(day: day, state: state(value, active: [])))
        XCTAssertEqual(ServerScoreDisplay.sleepLedger(day: day, state: state(value, active: [.sleepDebt]))?.balanceMin, -33)
        let noCapability = try snapshot(["capabilities": ["sleep_debt_min", "sleep_total_min"]])
        XCTAssertNil(ServerScoreDisplay.sleepLedger(day: day, state: state(noCapability, active: [.sleepDebt])))
        XCTAssertNil(ServerScoreDisplay.sleepTypical(.sleepTotal, day: day, state: state(noCapability, active: [.sleepTotal])))
        XCTAssertEqual(ServerScoreMetric.schema2.count, 13)
    }

    func testOwnedNullMissingAndFutureMethodDetailsRemainUnavailable() throws {
        let view = state(try snapshot(), active: [.sleepTotal, .sleepREM, .sleepDebt])
        XCTAssertEqual(ServerScoreDisplay.sleepTypical(.sleepTotal, day: day, state: view), 450)
        XCTAssertNil(ServerScoreDisplay.sleepTypical(.sleepREM, day: day, state: view))
        XCTAssertNil(ServerScoreDisplay.sleepLedger(day: "2026-09-14", state: view))
        var future = typicals; future["method"] = "future_model"
        let value = try snapshot(["details": ["sleep_typicals": future, "sleep_ledger": NSNull(), "future": true]])
        XCTAssertNil(ServerScoreDisplay.sleepTypical(.sleepTotal, day: day, state: state(value, active: [.sleepTotal])))
        XCTAssertNil(ServerScoreDisplay.sleepLedger(day: day, state: state(value, active: [.sleepDebt])))
    }

    func testLedgerRejectsCountMismatchFutureDuplicateAndUnboundedNumbers() throws {
        for change: [String: Any] in [["nightCount": 2], ["balanceMin": 1e40], ["habitualMidsleepSec": 86400],
            ["nights": [["day": "2026-09-16", "sleptMin": 420, "deltaMin": -60]]],
            ["nightCount": 2, "nights": [["day": day, "sleptMin": 420, "deltaMin": -60],
                                       ["day": day, "sleptMin": 420, "deltaMin": -60]]]] {
            var invalid = ledger; invalid.merge(change) { _, new in new }
            XCTAssertThrowsError(try snapshot(["details": ["sleep_ledger": invalid]]))
        }
    }

    func testTypedEfficiencyConvertsToFractionWithoutChangingCatalogPercent() throws {
        for percent in [0.0, 0.5, 92.0, 100.0] {
            let value = try snapshot(["capabilities": ["sleep_efficiency"],
                "daily": ["sleep_efficiency": 0.75],
                "metrics": ["sleep_efficiency": ["value": percent, "unit": "percent"]]])
            let view = state(value, active: [.sleepEfficiency])
            XCTAssertEqual(ServerScoreDisplay.daily(local: nil, day: day, state: view)?.efficiency, percent / 100)
            XCTAssertEqual(ServerScoreDisplay.series(.sleepEfficiency, through: day, state: view).first?.value, percent)
        }
        let missing = try snapshot(["capabilities": ["sleep_efficiency"], "daily": ["sleep_efficiency": 0.75],
                                   "metrics": ["sleep_efficiency": ["value": NSNull(), "unit": "percent"]]])
        XCTAssertNil(ServerScoreDisplay.efficiencyFraction(missing))
        let legacy = try snapshot(["capabilities": ["sleep_efficiency"], "daily": ["sleep_efficiency": 0.75]])
        XCTAssertEqual(ServerScoreDisplay.efficiencyFraction(legacy), 0.75)
    }

    private func chartSnapshot(metadataChanges: [String: Any] = [:], advertised: Bool = true) throws -> ServerScoreSnapshot {
        let key = "sleep_hr:" + sleepID
        var metadata: [String: Any] = ["schemaVersion": 1, "unit": "bpm", "bucketSeconds": 300,
                                      "method": "observed_mean_min_max", "sessionId": sleepID]
        metadata.merge(metadataChanges) { _, new in new }
        return try snapshot(["capabilities": advertised ? ["sleep_sessions", key] : ["sleep_sessions"],
            "sleep": [["id": sleepID, "start_at": "2026-09-15T00:00:00Z", "end_at": "2026-09-15T07:00:00Z",
                       "is_nap": false, "stages": []]],
            "charts": [key: [["start": 1789430400, "end": 1789430700, "value": 58, "count": 10],
                              ["start": 1789431000, "end": 1789431300, "value": 60, "count": 5]]],
            "chartMetadata": [key: metadata]])
    }

    func testSleepHRUsesAdvertisedStableSessionKeyAndRetainsGaps() throws {
        let value = try chartSnapshot()
        let points = ServerScoreDisplay.sleepHeartRatePoints(day: day, state: state(value, active: [.sleepSessions]))
        XCTAssertEqual(points.map(\.start), [1789430400, 1789431000])
        XCTAssertEqual(points.map(\.value), [58, 60])
        XCTAssertTrue(ServerScoreDisplay.sleepHeartRatePoints(day: day, state: state(value, active: [])).isEmpty)
        XCTAssertEqual(try ServerScoreResponse.decode(value.encoded(), requestedDay: day).snapshot, value)
    }

    func testSleepHRRejectsWrongIdentityUnitVersionOrUnadvertisedChart() throws {
        for changes: [String: Any] in [["sessionId": "other"], ["unit": "gravity_delta"], ["schemaVersion": 2],
                                      ["bucketSeconds": 30], ["method": "future"]] {
            let value = try chartSnapshot(metadataChanges: changes)
            XCTAssertTrue(ServerScoreDisplay.sleepHeartRatePoints(day: day, state: state(value, active: [.sleepSessions])).isEmpty)
        }
        let value = try chartSnapshot(advertised: false)
        XCTAssertTrue(ServerScoreDisplay.sleepHeartRatePoints(day: day, state: state(value, active: [.sleepSessions])).isEmpty)
    }
}
