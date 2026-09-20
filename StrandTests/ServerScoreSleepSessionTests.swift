import Foundation
import XCTest
import WhoopStore
#if !SERVER_SCORE_NATIVE_TESTS
import StrandImport
@testable import Strand
#endif

final class ServerScoreSleepSessionTests: XCTestCase {
    private let day = "2026-09-18"
    private let sessionID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    private let start = Int(ServerScoreDate.parse("2026-09-18T06:00:00Z")!.timeIntervalSince1970)

    private func snapshot(stages: [[String: Any]]? = nil, isNap: Bool = false,
                          revision: Int = 1, empty: Bool = false, identity: [String: Any] = [:],
                          capabilities: [String]? = nil) throws -> ServerScoreSnapshot {
        var sleep: [String: Any] = ["id": sessionID, "start_at": "2026-09-18T06:00:00Z",
            "end_at": "2026-09-18T07:00:00Z", "is_nap": isNap, "stages": stages ?? [
                ["start": start, "end": start + 300, "stage": "wake"],
                ["start": start + 300, "end": start + 1200, "stage": "light"],
                ["start": start + 1800, "end": start + 2700, "stage": "deep"],
                ["start": start + 2700, "end": start + 3600, "stage": "rem"]]]
        sleep.merge(identity) { _, new in new }
        var object: [String: Any] = ["schemaVersion": 2, "userId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "day": day,
            "timezone": "America/Los_Angeles", "algorithmVersion": "sleep-projection-v2",
            "inputRevision": revision, "resultRevision": revision, "computedAt": "2026-09-18T15:00:00Z",
            "status": empty ? "no_data" : "partial", "coverage": [:], "daily": NSNull(),
            "sleep": empty ? [] : [sleep]]
        if let capabilities { object["capabilities"] = capabilities }
        let response = try ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: object), requestedDay: day)
        return try XCTUnwrap(response.snapshot)
    }

    private func state(_ snapshot: ServerScoreSnapshot?, owned: Bool = true,
                       phase: ServerScoreDayState.Phase = .partial) -> ServerScoreViewState {
        let entry = ServerScoreDayState(snapshot: snapshot, phase: phase, fetchedAt: nil,
            cached: false, pending: phase == .pending, requestedInputRevision: nil, archiveStatus: nil)
        return ServerScoreViewState(generation: UUID(), revision: 1, currentDay: day, timezone: "America/Los_Angeles",
            configured: true, authenticated: true, capabilities: [.sleepSessions],
            activated: owned ? [.sleepSessions] : [], days: [day: entry])
    }

    func testCanonicalEpochArrayWorksWithRealHealthWritebackParserAndPreservesGaps() throws {
        let original = try snapshot().sleep[0]
        let row = ServerScoreSleepPresentation.session(original)
        let bytes = Data(try XCTUnwrap(row.stagesJSON).utf8)
        XCTAssertEqual(try JSONDecoder().decode([ServerScoreSleep.Stage].self, from: bytes), original.stages)
        let intervals = HealthWriteback.stageIntervals(stagesJSON: row.stagesJSON, sessionStart: row.startTs, sessionEnd: row.endTs)
        XCTAssertEqual(intervals.map(\.kind), [.awake, .light, .deep, .rem])
        XCTAssertEqual(intervals.map(\.start), [start, start + 300, start + 1800, start + 2700])
        XCTAssertEqual(intervals.map(\.end), [start + 300, start + 1200, start + 2700, start + 3600])
        XCTAssertEqual(intervals.reduce(0) { $0 + $1.end - $1.start }, 3000)
    }

    func testEmptyStagesStayExplicitlyEmptyAndUnknownMetricsFlagsStayUnknown() throws {
        let row = ServerScoreSleepPresentation.session(try snapshot(stages: []).sleep[0])
        XCTAssertEqual(row.stagesJSON, "[]")
        XCTAssertNil(row.efficiency)
        XCTAssertNil(row.restingHr)
        XCTAssertNil(row.avgHrv)
        XCTAssertNil(row.stagingSparse)
        XCTAssertNil(row.startTsAdjusted)
        XCTAssertFalse(row.userEdited)
        XCTAssertTrue(HealthWriteback.stageIntervals(stagesJSON: row.stagesJSON, sessionStart: row.startTs, sessionEnd: row.endTs).isEmpty)
    }

    func testSingleStageIsNotReconstructed() throws {
        let original = try snapshot(stages: [["start": start + 60, "end": start + 240, "stage": "awake"]]).sleep[0]
        let row = ServerScoreSleepPresentation.session(original)
        let intervals = HealthWriteback.stageIntervals(stagesJSON: row.stagesJSON, sessionStart: row.startTs, sessionEnd: row.endTs)
        XCTAssertEqual(intervals, [.init(start: start + 60, end: start + 240, kind: .awake)])
    }

    func testProjectionRetainsUUIDNapAndSnapshotProvenance() throws {
        let source = try snapshot(isNap: true, revision: 8)
        let item = try XCTUnwrap(ServerScoreSleepPresentation.projections(day: day, state: state(source)).first)
        XCTAssertEqual(item.sleep.id, sessionID)
        XCTAssertTrue(item.sleep.isNap)
        XCTAssertEqual(item.sleep, source.sleep[0])
        XCTAssertEqual(item.userID, source.userId)
        XCTAssertEqual(item.sourceDeviceID, source.sourceDeviceId)
        XCTAssertEqual(item.day, day)
        XCTAssertEqual(item.timeZoneID, source.timezone)
        XCTAssertEqual(item.algorithmVersion, source.algorithmVersion)
        XCTAssertEqual(item.schemaVersion, 2)
        XCTAssertEqual(item.inputRevision, 8)
        XCTAssertEqual(item.resultRevision, 8)
        XCTAssertEqual(item.session.stagesJSON, source.sleep[0].stagesJSON)
    }

    func testMissingOwnedSnapshotNeverSuppliesLocalSessions() throws {
        for phase in [ServerScoreDayState.Phase.loading, .pending, .failed, .unsupported, .noData] {
            let current = state(nil, phase: phase)
            XCTAssertTrue(current.owns(.sleepSessions))
            XCTAssertTrue(ServerScoreSleepPresentation.projections(day: day, state: current).isEmpty)
        }
        XCTAssertTrue(ServerScoreSleepPresentation.projections(day: day, state: state(try snapshot(), owned: false)).isEmpty)
    }

    func testCurrentResultCapabilityWithdrawalDoesNotPresentPreviouslyOwnedSleep() throws {
        for capabilities in [[], ["hrv_rmssd_ms"]] {
            let current = state(try snapshot(capabilities: capabilities))
            XCTAssertTrue(current.owns(.sleepSessions))
            XCTAssertFalse(try XCTUnwrap(current.days[day]?.snapshot).sleep.isEmpty)
            XCTAssertTrue(ServerScoreSleepPresentation.projections(day: day, state: current).isEmpty)
        }
        let cached = state(try snapshot(capabilities: ["sleep_sessions"]), phase: .offline)
        XCTAssertEqual(ServerScoreSleepPresentation.projections(day: day, state: cached).count, 1)
    }

    func testOptionalEditIdentityPreservesOriginalBoundsAndStableEntity() throws {
        let entity = "sleep:" + sessionID
        let result = try snapshot(identity: ["originalStart": start - 1800, "originalEnd": start + 1800, "editEntity": entity])
        let sleep = result.sleep[0]
        XCTAssertEqual(sleep.start, start)
        XCTAssertEqual(sleep.anchoredOriginalStart, start - 1800)
        XCTAssertEqual(sleep.anchoredOriginalEnd, start + 1800)
        XCTAssertEqual(sleep.resolvedEditEntity, entity)
        XCTAssertEqual(sleep.resolvedEditEntity, "sleep:" + sleep.id)
        XCTAssertEqual(try ServerScoreResponse.decode(result.encoded(), requestedDay: day).snapshot, result)
        XCTAssertEqual(ServerScoreSleepPresentation.projections(day: day, state: state(result)).first?.sleep.editEntity, entity)
    }

    func testLegacyEditAnchorUsesOriginalSnapshotAndNormalizesUUID() throws {
        let sleep = try snapshot(identity: ["id": sessionID.uppercased()]).sleep[0]
        XCTAssertNil(sleep.originalStart)
        XCTAssertNil(sleep.originalEnd)
        XCTAssertNil(sleep.editEntity)
        XCTAssertEqual(sleep.anchoredOriginalStart, start)
        XCTAssertEqual(sleep.anchoredOriginalEnd, start + 3600)
        XCTAssertEqual(sleep.resolvedEditEntity, "sleep:" + sessionID)
    }

    func testMalformedEditIdentitiesAndOriginalBoundsRejected() throws {
        for identity: [String: Any] in [["originalStart": -1], ["originalStart": start, "originalEnd": start],
            ["originalEnd": 253402300800], ["originalStart": 1.5], ["editEntity": "sleep:invalid"],
            ["editEntity": "sleep:CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"], ["editEntity": "other:" + sessionID],
            ["originalStart": start, "originalEnd": start + 3600],
            ["originalStart": start, "originalEnd": start + 3600, "editEntity": "sleep:dddddddd-dddd-dddd-dddd-dddddddddddd"],
            ["originalStart": start, "originalEnd": start + 3600, "editEntity": "sleep:" + sessionID.uppercased()]] {
            XCTAssertThrowsError(try snapshot(identity: identity))
        }
    }

    func testRetainedSnapshotAndCompleteReplacementDoNotAppendOldSessions() throws {
        let first = try snapshot()
        let retained = ServerScoreSleepPresentation.projections(day: day, state: state(first, phase: .offline))
        XCTAssertEqual(retained.count, 1)
        let corrected = try snapshot(stages: [], revision: 2)
        let changed = ServerScoreSleepPresentation.projections(day: day, state: state(corrected))
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed[0].sleep.id, retained[0].sleep.id)
        XCTAssertEqual(changed[0].session.stagesJSON, "[]")
        XCTAssertTrue(ServerScoreSleepPresentation.projections(day: day, state: state(try snapshot(revision: 3, empty: true))).isEmpty)
    }

    func testDerivedStageJSONDoesNotChangeWireSchemaAndRoundTrips() throws {
        let original = try snapshot()
        let bytes = try original.encoded()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let rows = try XCTUnwrap(object["sleep"] as? [[String: Any]])
        XCTAssertNil(rows[0]["stagesJSON"])
        let restored = try ServerScoreResponse.decode(bytes, requestedDay: day).snapshot
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored?.sleep[0].stagesJSON, original.sleep[0].stagesJSON)
    }

    #if !SERVER_SCORE_NATIVE_TESTS
    @MainActor
    func testTodayLabelsServerSnapshotWithoutExtendingFusionSource() {
        XCTAssertEqual(TodayView.provenanceDisplayLabel(rawSource: "server-snapshot", deviceId: "strap"), String(localized: "Server snapshot"))
        XCTAssertEqual(TodayView.todayScoreProviderLabel(sourceId: "server-snapshot", brand: "WHOOP"), String(localized: "Server snapshot"))
    }
    #endif
}
