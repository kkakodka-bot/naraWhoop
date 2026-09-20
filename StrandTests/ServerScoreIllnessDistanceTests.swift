import Foundation
import XCTest
import StrandAnalytics
#if !SERVER_SCORE_NATIVE_TESTS
@testable import Strand
#endif

/// Synthetic wire controls; actual emitted values are covered by the populated-fixture suite.
final class ServerScoreIllnessDistanceTests: XCTestCase {
    private let day = "2026-09-15"
    private let fields: Set<ServerScoreMetric> = [.illnessScore, .illnessDistance]
    private var illness: [String: Any] {
        ["level": "suppressed", "signalCount": 3, "suppressedBy": ["alcohol"],
         "distanceFires": false, "distanceIsAlertGate": false, "wellnessOnly": true,
         "distanceDeviatingFeatures": 1, "distanceUsedDiagonalFallback": false,
         "firedSignals": [], "copy": "Synthetic emitted wellness copy"]
    }
    private var reading: [String: Any] {
        ["value": 7.25, "unit": "dimensionless", "method": "IllnessDistance_identity_correlation"]
    }
    private func snapshot(illness changed: [String: Any]? = nil,
                          reading metric: [String: Any]? = nil,
                          extra: [String: Any] = [:]) throws -> ServerScoreSnapshot {
        var object: [String: Any] = ["schemaVersion": 2,
            "userId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "sourceDeviceId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
            "day": day, "timezone": "UTC", "algorithmVersion": "synthetic-distance", "inputRevision": 1, "resultRevision": 2,
            "computedAt": "2026-09-15T12:00:00Z", "status": "partial", "coverage": [:], "sleep": [],
            "capabilities": fields.map(\.rawValue),
            "details": ["contextPolicy": "as-of-context-v1", "illness": changed ?? illness],
            "metrics": ["illness_distance": metric ?? reading,
                        "illness_score": ["value": 32, "unit": "score_0_100", "method": "IllnessSignalEngine"]]]
        object.merge(extra) { _, new in new }
        let response = try ServerScoreResponse.decode(JSONSerialization.data(withJSONObject: object), requestedDay: day)
        return try XCTUnwrap(response.snapshot)
    }
    private func state(_ snapshot: ServerScoreSnapshot, active: Set<ServerScoreMetric>? = nil,
                       configured: Bool = true, authenticated: Bool = true) -> ServerScoreViewState {
        .init(generation: UUID(), revision: 1, currentDay: day, timezone: "UTC", configured: configured,
              authenticated: authenticated, capabilities: fields, activated: active ?? fields,
              days: [day: .init(snapshot: snapshot, phase: .offline, fetchedAt: nil, cached: true,
                               pending: false, requestedInputRevision: nil, archiveStatus: nil)])
    }
    private func distance(_ snapshot: ServerScoreSnapshot) -> IllnessDistance.Result? {
        ServerScoreContextPresentation.illnessDistance(day: day, state: state(snapshot))
    }

    func testExactTypedResultDoesNotAliasCountRecomputeFiresOrActivateAnAlert() throws {
        // True fallback is a synthetic decoding control, not a claim that the identity kernel emits it.
        for (count, fires, fallback) in [(0, false, false), (1, false, true), (4, true, false)] {
            var value = illness
            value["distanceDeviatingFeatures"] = count
            value["distanceFires"] = fires
            value["distanceUsedDiagonalFallback"] = fallback
            let snapshot = try snapshot(illness: value)
            let actual = try XCTUnwrap(distance(snapshot))
            XCTAssertEqual(actual.distance, 7.25)
            XCTAssertEqual(actual.deviatingFeatures, count)
            XCTAssertNotEqual(actual.deviatingFeatures, snapshot.details?.illness?.signalCount)
            XCTAssertEqual(actual.fires, fires)
            XCTAssertEqual(actual.usedDiagonalFallback, fallback)
            let score = try XCTUnwrap(ServerScoreContextPresentation.illness(day: day, state: state(snapshot)))
            XCTAssertEqual(score.level, .suppressed)
            XCTAssertNil(score.message)
            XCTAssertFalse(try XCTUnwrap(snapshot.details?.illness?.distanceIsAlertGate))
        }
    }

    func testAbsentNullAndPartialLegacyFieldsDecodeButNeverInventDefaults() throws {
        for keys in [["distanceDeviatingFeatures"], ["distanceUsedDiagonalFallback"],
                     ["distanceDeviatingFeatures", "distanceUsedDiagonalFallback"]] {
            for null in [false, true] {
                var value = illness
                for key in keys { if null { value[key] = NSNull() } else { value.removeValue(forKey: key) } }
                let snapshot = try snapshot(illness: value)
                XCTAssertNil(distance(snapshot))
                XCTAssertNotNil(ServerScoreContextPresentation.illness(day: day, state: state(snapshot)))
                XCTAssertEqual(snapshot.value(.illnessDistance), 7.25, "Scalar remains separately readable")
            }
        }
    }

    func testFeatureBoundsAndExactWireTypesRejectMalformedExtensions() throws {
        for bad: Any in [-1, 5, 1.5, "2", true] {
            var value = illness; value["distanceDeviatingFeatures"] = bad
            XCTAssertThrowsError(try snapshot(illness: value))
        }
        for bad: Any in ["false", 0, 1] {
            var value = illness; value["distanceUsedDiagonalFallback"] = bad
            XCTAssertThrowsError(try snapshot(illness: value))
        }
        for count in 0...4 {
            var value = illness; value["distanceDeviatingFeatures"] = count
            XCTAssertEqual(try XCTUnwrap(distance(snapshot(illness: value))).deviatingFeatures, count)
        }
    }

    func testIndependentDistanceOwnershipRequiresConfigurationAuthAndActivation() throws {
        let snapshot = try snapshot(extra: ["capabilities": ["illness_distance"]])
        for view in [state(snapshot, active: []), state(snapshot, active: [.illnessScore]),
                     state(snapshot, configured: false), state(snapshot, authenticated: false)] {
            XCTAssertNil(ServerScoreContextPresentation.illnessDistance(day: day, state: view))
        }
        let view = state(snapshot, active: [.illnessDistance])
        XCTAssertNotNil(ServerScoreContextPresentation.illnessDistance(day: day, state: view))
        XCTAssertNil(ServerScoreContextPresentation.illness(day: day, state: view))
    }

    func testSupportedMethodUnitAndReadingStatusAreRequiredWithoutVersionPinning() throws {
        for key in ["method", "unit"] {
            for bad in ["", "future"] {
                var metric = reading; metric[key] = bad
                XCTAssertNil(distance(try snapshot(reading: metric)))
            }
            var metric = reading; metric.removeValue(forKey: key)
            XCTAssertNil(distance(try snapshot(reading: metric)))
        }
        for status in ["unknown", "unavailable", "pending"] {
            var metric = reading; metric["status"] = status
            XCTAssertNil(distance(try snapshot(reading: metric)))
        }
        var metric = reading; metric["status"] = "available"
        XCTAssertNotNil(distance(try snapshot(reading: metric, extra: ["algorithmVersion": "another-supported-producer"])))
    }

    func testSupportedParentPolicyAndWellnessBoundaryAreRequired() throws {
        for details: [String: Any] in [[:], ["contextPolicy": "as-of-context-v1", "illness": NSNull()],
            ["illness": illness], ["contextPolicy": "future-policy", "illness": illness]] {
            XCTAssertNil(distance(try snapshot(extra: ["details": details])))
        }
        for (key, bad) in [("distanceIsAlertGate", true), ("wellnessOnly", false)] {
            var value = illness; value[key] = bad
            XCTAssertThrowsError(try snapshot(illness: value))
        }
        XCTAssertThrowsError(try snapshot(extra: ["schemaVersion": 3]))
    }

    func testOwnedNullNoDataWithdrawalAndWrongDayCannotUseRetainedOrLocalResults() throws {
        var nullMetric = reading; nullMetric["value"] = NSNull()
        for snapshot in [try snapshot(reading: nullMetric), try snapshot(extra: ["metrics": [:]]),
                         try snapshot(extra: ["capabilities": []]),
                         try snapshot(extra: ["status": "no_data", "metrics": [:]])] {
            let view = state(snapshot)
            XCTAssertTrue(view.owns(.illnessDistance))
            XCTAssertNil(ServerScoreContextPresentation.illnessDistance(day: day, state: view))
            XCTAssertNil(view.value(.illnessDistance, day: day, local: 999))
        }
        XCTAssertNil(ServerScoreContextPresentation.illnessDistance(day: "2026-09-14", state: state(try snapshot())))
    }

    func testDistanceDoesNotDependOnScoreEnumCopyLabelsOrScoreScalar() throws {
        var value = illness
        value["level"] = "future-score-level"
        value.removeValue(forKey: "copy"); value.removeValue(forKey: "firedSignals")
        let snapshot = try snapshot(illness: value, extra: ["metrics": ["illness_distance": reading]])
        XCTAssertNotNil(distance(snapshot))
        XCTAssertNil(ServerScoreContextPresentation.illness(day: day, state: state(snapshot)))
    }

    func testUnknownOptionalFieldsAndRoundTripPreserveTypedDistance() throws {
        var value = illness; value["futureOptional"] = ["version": 99]
        let snapshot = try snapshot(illness: value)
        let roundTrip = try XCTUnwrap(ServerScoreResponse.decode(snapshot.encoded(), requestedDay: day).snapshot)
        XCTAssertEqual(roundTrip, snapshot)
        XCTAssertEqual(try XCTUnwrap(distance(roundTrip)).deviatingFeatures, 1)
        XCTAssertEqual(roundTrip.details?.illness?.distanceUsedDiagonalFallback, false)
    }
}
