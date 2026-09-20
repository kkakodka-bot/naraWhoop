import Foundation
import XCTest
#if !SERVER_SCORE_NATIVE_TESTS
@testable import Strand
#endif

final class ServerScoreSnapshotV2Tests: XCTestCase {
    private let day = "2026-09-18"
    private func payload(_ updates: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = [
            "schemaVersion": 2, "userId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "day": day,
            "timezone": "America/Los_Angeles", "algorithmVersion": "future-compatible-7",
            "inputRevision": 2, "resultRevision": 3, "computedAt": "2026-09-18T14:00:00.123Z",
            "dataThrough": "2026-09-18T13:59:00Z", "status": "partial",
            "coverage": ["hrSamples": 19, "gaps": ["historical_state"]],
            "daily": ["hrv_rmssd_ms": 42.0, "resting_hr_bpm": NSNull()], "sleep": []
        ]
        object.merge(updates) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func decode(_ updates: [String: Any] = [:]) throws -> ServerScoreResponse {
        try ServerScoreResponse.decode(payload(updates), requestedDay: day)
    }
    private func state(_ entry: ServerScoreDayState?, active: Bool = true,
                       authenticated: Bool = true, configured: Bool = true,
                       capabilities: Set<ServerScoreMetric> = ServerScoreMetric.schema2) -> ServerScoreViewState {
        ServerScoreViewState(generation: UUID(), revision: 1, currentDay: day, timezone: "America/Los_Angeles",
            configured: configured, authenticated: authenticated, capabilities: capabilities,
            activated: active ? [.hrv, .restingHR] : [], days: entry.map { [day: $0] } ?? [:])
    }
    private func entry(_ snapshot: ServerScoreSnapshot?) -> ServerScoreDayState {
        ServerScoreDayState(snapshot: snapshot, phase: .partial, fetchedAt: Date(), cached: false,
                            pending: false, requestedInputRevision: nil, archiveStatus: nil)
    }
    func testSchemaTwoAcceptsUnknownAlgorithmAndOptionalFields() throws {
        let response = try decode(["futureExtension": ["nested": true]])
        XCTAssertEqual(response.snapshot?.algorithmVersion, "future-compatible-7")
        XCTAssertEqual(response.snapshot?.daily?[.hrv], 42)
        XCTAssertNil(response.snapshot?.daily?[.restingHR])
        XCTAssertEqual(response.snapshot?.supported, ServerScoreMetric.schema2)
    }
    func testMutableEnvelopeDoesNotAlterImmutableBytes() throws {
        let first = try decode(["requestedInputRevision": 2, "pending": false, "archiveStatus": "ready"])
        let later = try decode(["requestedInputRevision": 7, "pending": true, "archiveStatus": "pending"])
        XCTAssertEqual(try first.snapshot?.encoded(), try later.snapshot?.encoded())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(later.snapshot?.encoded())) as? [String: Any])
        XCTAssertNil(object["pending"])
        XCTAssertNil(object["requestedInputRevision"])
        XCTAssertNil(object["archiveStatus"])
        XCTAssertTrue(later.pending)
        XCTAssertEqual(later.requestedInputRevision, 7)
    }
    func testNoDataIsAuthoritativeEmptyReplacement() throws {
        let response = try decode(["status": "no_data", "daily": NSNull(), "sleep": []])
        XCTAssertNotNil(response.snapshot)
        XCTAssertTrue(response.snapshot!.sleep.isEmpty)
        XCTAssertNil(state(entry(response.snapshot)).value(.hrv, day: day, local: 99))
        XCTAssertThrowsError(try decode(["status": "no_data"]))
    }
    func testPendingFailedUnsupportedAreNotTombstones() throws {
        for status in ["pending", "failed", "unsupported"] {
            let response = try decode(["status": status, "daily": NSNull(), "resultRevision": NSNull()])
            XCTAssertNil(response.snapshot)
        }
    }
    func testUnsupportedSchemaIsExplicit() throws {
        XCTAssertThrowsError(try decode(["schemaVersion": 3])) {
            XCTAssertEqual($0 as? ServerScoreDecodeError, .unsupportedSchema(3))
        }
    }
    func testOwnershipRequiresAllFourGates() throws {
        for view in [state(nil, active: false), state(nil, authenticated: false),
                     state(nil, configured: false), state(nil, capabilities: [])] {
            XCTAssertEqual(view.value(.hrv, day: day, local: 99), 99)
        }
        XCTAssertNil(state(nil).value(.hrv, day: day, local: 99))
    }
    func testActivatedNullAndTransientStatesNeverReadLocal() throws {
        let snapshot = try decode().snapshot
        for phase in [ServerScoreDayState.Phase.loading, .offline, .failed, .pending, .unsupported] {
            let view = state(entry(snapshot).retaining(phase))
            XCTAssertEqual(view.value(.hrv, day: day, local: 99), 42)
            XCTAssertNil(view.value(.restingHR, day: day, local: 88))
            XCTAssertFalse(view.days[day]!.note.isEmpty)
        }
    }
    func testCapabilitiesGrantOnlyKnownAdvertisedFields() throws {
        let snapshot = try decode(["capabilities": ["hrv_rmssd_ms", "future_metric"]]).snapshot!
        XCTAssertEqual(snapshot.supported, [.hrv])
        let view = state(entry(snapshot), capabilities: snapshot.supported)
        XCTAssertEqual(view.value(.restingHR, day: day, local: 88), 88)
    }
    func testWrongDayIdentityRevisionTimezoneRejected() throws {
        for change: [String: Any] in [["day": "2026-09-17"], ["userId": "bad"], ["sourceDeviceId": "bad"],
                                    ["resultRevision": 0], ["inputRevision": -1], ["timezone": "Not/AZone"]] {
            XCTAssertThrowsError(try decode(change))
        }
    }
    func testInvalidNumbersAndOversizedPayloadRejected() throws {
        for value in [-1.0, 1e100] {
            XCTAssertThrowsError(try decode(["daily": ["resting_hr_bpm": value]]))
        }
        XCTAssertThrowsError(try ServerScoreResponse.decode(Data(repeating: 32, count: 512 * 1024 + 1), requestedDay: day)) {
            XCTAssertEqual($0 as? ServerScoreDecodeError, .tooLarge)
        }
    }
    private func sleep(_ stages: [[String: Any]]) -> [String: Any] {
        ["id": "cccccccc-cccc-cccc-cccc-cccccccccccc", "start_at": "2026-09-18T06:00:00Z",
         "end_at": "2026-09-18T07:00:00Z", "is_nap": false, "stages": stages]
    }
    func testSessionEpochsAndStableIDRoundTrip() throws {
        let start = Int64(ServerScoreDate.parse("2026-09-18T06:00:00Z")!.timeIntervalSince1970)
        let response = try decode(["sleep": [sleep([["start": start, "end": start + 3600, "stage": "light"]])]])
        let snapshot = try XCTUnwrap(response.snapshot)
        XCTAssertEqual(snapshot.sleep[0].start, Int(start))
        XCTAssertEqual(snapshot.sleep[0].end, Int(start + 3600))
        XCTAssertEqual(try ServerScoreResponse.decode(snapshot.encoded(), requestedDay: day).snapshot, snapshot)
    }
    func testInvalidOrOverlappingStagesAndDuplicateSessionsRejected() throws {
        let start = Int64(ServerScoreDate.parse("2026-09-18T06:00:00Z")!.timeIntervalSince1970)
        for stages in [
            [["start": start, "end": start + 60, "stage": "fiction"]],
            [["start": start, "end": start + 3601, "stage": "rem"]],
            [["start": start, "end": start + 120, "stage": "light"], ["start": start + 60, "end": start + 180, "stage": "deep"]]
        ] {
            XCTAssertThrowsError(try decode(["sleep": [sleep(stages)]]))
        }
        XCTAssertThrowsError(try decode(["sleep": [sleep([]), sleep([])]]))
    }
    func testCalendarMidnightAndDSTUseZoneRatherThanFixedSeconds() {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(ServerScoreDate.day(ServerScoreDate.parse("2026-09-18T06:59:59Z")!, timeZone: zone), "2026-09-17")
        XCTAssertEqual(ServerScoreDate.day(ServerScoreDate.parse("2026-09-18T07:00:00Z")!, timeZone: zone), day)
        XCTAssertEqual(ServerScoreDate.offsetDay("2026-03-08", by: 1, timeZone: zone), "2026-03-09")
        XCTAssertEqual(ServerScoreDate.offsetDay("2026-11-01", by: -1, timeZone: zone), "2026-10-31")
        XCTAssertFalse(ServerScoreDate.isDay("2026-02-30"))
    }
    static let nativeTests = [
        ("testSchemaTwoAcceptsUnknownAlgorithmAndOptionalFields", testSchemaTwoAcceptsUnknownAlgorithmAndOptionalFields),
        ("testMutableEnvelopeDoesNotAlterImmutableBytes", testMutableEnvelopeDoesNotAlterImmutableBytes),
        ("testNoDataIsAuthoritativeEmptyReplacement", testNoDataIsAuthoritativeEmptyReplacement),
        ("testPendingFailedUnsupportedAreNotTombstones", testPendingFailedUnsupportedAreNotTombstones),
        ("testUnsupportedSchemaIsExplicit", testUnsupportedSchemaIsExplicit),
        ("testOwnershipRequiresAllFourGates", testOwnershipRequiresAllFourGates),
        ("testActivatedNullAndTransientStatesNeverReadLocal", testActivatedNullAndTransientStatesNeverReadLocal),
        ("testCapabilitiesGrantOnlyKnownAdvertisedFields", testCapabilitiesGrantOnlyKnownAdvertisedFields),
        ("testWrongDayIdentityRevisionTimezoneRejected", testWrongDayIdentityRevisionTimezoneRejected),
        ("testInvalidNumbersAndOversizedPayloadRejected", testInvalidNumbersAndOversizedPayloadRejected),
        ("testSessionEpochsAndStableIDRoundTrip", testSessionEpochsAndStableIDRoundTrip),
        ("testInvalidOrOverlappingStagesAndDuplicateSessionsRejected", testInvalidOrOverlappingStagesAndDuplicateSessionsRejected),
        ("testCalendarMidnightAndDSTUseZoneRatherThanFixedSeconds", testCalendarMidnightAndDSTUseZoneRatherThanFixedSeconds)
    ]
}
