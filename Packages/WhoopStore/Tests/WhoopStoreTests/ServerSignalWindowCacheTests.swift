import XCTest
@testable import WhoopStore

final class ServerSignalWindowCacheTests: XCTestCase {
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let device = "22222222-2222-4222-8222-222222222222"
    private let day = "2026-09-21"

    private func window(_ kind: String = "hrv") -> [String: Any] {
        let duration = kind == "spo2" ? 900 : 300
        return [
            "schema_version": 1, "algorithm_version": "sensor-windows-1",
            "user_id": owner, "device_id": device, "window_id": "33333333-3333-4333-8333-333333333333",
            "kind": kind, "start": 1800, "end": 1800 + duration,
            "duration_seconds": duration, "stride_seconds": duration,
            "input_revision": "7", "result_revision": "7", "required_revision": 7,
            "publication_status": "shadow", "measurement_status": kind == "spo2" ? "blocked" : "unavailable",
            "reason": "capture_metadata_unqualified", "freshness_status": "snapshot",
            "modality": ["hrv", "spo2"].contains(kind) ? "unknown" : kind,
            "unit": ["hrv": "ms", "ppg": "bpm", "imu": "m_s2_and_rad_s", "temperature": "degC_skin", "spo2": "percent"][kind]!,
            "values": NSNull(), "quality": ["unavailable_signals": ["motion"]],
            "observed_fraction": NSNull(), "maximum_gap_seconds": NSNull(),
            "observed_through": NSNull(), "source": NSNull(),
            "computed_at": "2026-09-21T00:05:00Z", "published_at": "2026-09-21T00:05:01Z",
            "computation_mode": "retrospective", "provenance": "vps_estimate",
            "calibration_status": "not_reference_validated", "quality_policy_version": "engineering-sensor-quality-1",
            "preprocess_version": "qualified-raw-features-1"
        ]
    }

    private func decode(_ row: [String: Any]) -> ServerSignalWindowCache? {
        ServerSignalWindowCache(row, owner: owner, device: device)
    }

    private func snapshot(_ rows: [[String: Any]]) throws -> ServerScoreDayCache {
        let body: [String: Any] = ["server_scoring": [
            "schema_version": 2, "algorithm_version": "frwhoop-physiology-2", "user_id": owner, "day": day,
            "features": ["hrv": ["status": "unavailable", "device_id": device,
                                  "algorithm_version": "frwhoop-physiology-2", "publication_status": "shadow"]],
            "daily": ["hrv_rmssd_ms": 99], "nights": [],
            "signal_windows_device_id": device, "signal_windows": rows
        ]]
        return try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: body), day: day, ownerId: owner)
    }

    func testSupportedModalitiesPreserveExplicitMissingnessAndMeasuredZeroCoverage() throws {
        for kind in ["hrv", "ppg", "imu", "temperature", "spo2"] {
            XCTAssertNil(try XCTUnwrap(decode(window(kind))).observedFraction)
            var row = window(kind); row["observed_fraction"] = 0; row["maximum_gap_seconds"] = 300
            XCTAssertEqual(try XCTUnwrap(decode(row)).observedFraction, 0)
        }
        for modality in ["ppg_ibi", "ecg_nn"] {
            var row = window(); row["modality"] = modality
            XCTAssertEqual(try XCTUnwrap(decode(row)).modality, modality)
        }
        var invalid = window("ppg"); invalid["modality"] = "ecg_nn"
        XCTAssertNil(decode(invalid))
    }

    func testOwnerDeviceAndShadowAuthorizationAreMandatory() {
        let mutations: [(String, Any)] = [
            ("user_id", "another-owner"), ("device_id", "another-device"),
            ("algorithm_version", "another-algorithm"), ("schema_version", 2), ("schema_version", true),
            ("publication_status", "canonical"), ("measurement_status", "available"), ("window_id", "not-a-uuid"),
            ("provenance", "device_reported"), ("unit", "bpm"), ("calibration_status", "validated")
        ]
        for (key, value) in mutations {
            var row = window(); row[key] = value
            XCTAssertNil(decode(row), "\(key)=\(value)")
        }
        var emptyOwner = window(); emptyOwner["user_id"] = ""
        XCTAssertNil(ServerSignalWindowCache(emptyOwner, owner: "", device: device))
        var unblocked = window("spo2"); unblocked["measurement_status"] = "unqualified"
        XCTAssertNil(decode(unblocked))
    }

    func testNumericalValuesCannotEnterThroughShadowDiagnostics() {
        for value: Any in [["observed_rmssd_ms": 44], [], 0, "null", false] {
            var row = window(); row["values"] = value
            XCTAssertNil(decode(row))
        }
        var absent = window(); absent.removeValue(forKey: "values")
        XCTAssertNil(decode(absent))
    }

    func testTimingRequiresExactIntegralAlignedBoundedWindows() {
        let mutations: [(String, Any)] = [
            ("start", -300), ("start", 1801), ("start", 1800.5), ("start", "1800"), ("start", true),
            ("end", 2099), ("end", Int64(4_102_444_801)), ("end", Int64.min),
            ("duration_seconds", 900), ("duration_seconds", "300"), ("stride_seconds", 60)
        ]
        for (key, value) in mutations {
            var row = window(); row[key] = value
            XCTAssertNil(decode(row), "\(key)=\(value)")
        }
        let start = Int64.max / 300 * 300
        var overflow = window(); overflow["start"] = start; overflow["end"] = start &+ 300
        XCTAssertNil(decode(overflow))
        var unaligned = window("spo2"); unaligned["start"] = 2100; unaligned["end"] = 3000
        XCTAssertNil(decode(unaligned))
    }

    func testRevisionIdentityAndFreshnessAreExactWithoutIntegerCoercion() throws {
        for revision: Any in ["0", "-1", "+7", "07", "7.0", " 7", "9223372036854775808", 7, true] {
            var row = window(); row["input_revision"] = revision; row["result_revision"] = revision
            XCTAssertNil(decode(row), "\(revision)")
        }
        for (key, value): (String, Any) in [("result_revision", "8"), ("result_revision", "07"),
                                          ("required_revision", "7"), ("required_revision", 0), ("required_revision", 8)] {
            var row = window(); row[key] = value
            XCTAssertNil(decode(row), "\(key)=\(value)")
        }
        var stale = window(); stale["required_revision"] = 8; stale["freshness_status"] = "stale"
        XCTAssertEqual(try XCTUnwrap(decode(stale)).freshnessStatus, "stale")
        var unknownRequired = window(); unknownRequired["required_revision"] = NSNull()
        XCTAssertNotNil(decode(unknownRequired))
        var exactLarge = window(); exactLarge["input_revision"] = String(Int64.max)
        exactLarge["result_revision"] = String(Int64.max); exactLarge["required_revision"] = Int64.max
        XCTAssertEqual(try XCTUnwrap(decode(exactLarge)).inputRevision, Int64.max)
    }

    func testMissingRequiredFieldsAndMalformedMissingnessAreRejected() {
        for key in ["observed_fraction", "maximum_gap_seconds", "observed_through", "source", "published_at",
                    "reason", "required_revision", "quality", "computed_at", "quality_policy_version", "preprocess_version", "stride_seconds"] {
            var row = window(); row.removeValue(forKey: key)
            XCTAssertNil(decode(row), key)
        }
        let mutations: [(String, Any)] = [
            ("observed_fraction", "0.5"), ("observed_fraction", true), ("observed_fraction", 1.01), ("observed_fraction", -0.01),
            ("observed_fraction", Double.nan), ("maximum_gap_seconds", Double.infinity),
            ("maximum_gap_seconds", 301), ("observed_through", 2101), ("observed_through", 1799),
            ("source", 0), ("reason", NSNull()), ("reason", ""), ("reason", "not a reason"), ("reason", "unqualified\n"),
            ("quality", []), ("computed_at", " ")
        ]
        for (key, value) in mutations {
            var row = window(); row[key] = value
            XCTAssertNil(decode(row), "\(key)=\(value)")
        }
    }

    func testDatabaseCacheRoundTripKeepsDiagnosticsButCannotActivateCanonicalHrv() async throws {
        var row = window(); row["analysis_status"] = "available"; row["measurement_status"] = "unqualified"
        row["reason"] = "not_reference_validated"; row["acquisition_contract_sha256"] = String(repeating: "a", count: 64)
        let original = try snapshot([row])
        let store = try await WhoopStore.inMemory()
        let persistence = ServerScoreCacheStore(db: store.registryWriter)
        try persistence.upsert(original)
        let restored = try XCTUnwrap(persistence.load(ownerId: owner, day: day))
        XCTAssertEqual(original.signalWindows, restored.signalWindows)
        XCTAssertEqual(restored.signalWindows.count, 1)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(restored.rawSnapshotJSON).utf8)) as? [String: Any])
        let overlay = try XCTUnwrap(root["server_scoring"] as? [String: Any])
        let retained = try XCTUnwrap((overlay["signal_windows"] as? [[String: Any]])?.first)
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: retained, options: [.sortedKeys]))
        XCTAssertEqual(restored.features["hrv"]?.isCanonicalAvailable, false)
        XCTAssertNil(ServerVitalSelection.resolve(.hrv, serverEnabled: true, selectedDay: day, overlay: restored, localValue: nil).value)
        row["values"] = ["heart_rate_bpm": 99]
        XCTAssertTrue(try snapshot([row]).signalWindows.isEmpty)
    }

    func testCachedEnvelopeScopeAndWindowCountAreBounded() throws {
        var ownerMismatch = try snapshot([window()]); ownerMismatch.ownerId = "another-owner"
        XCTAssertTrue(ownerMismatch.signalWindows.isEmpty)
        let original = try snapshot([window()])
        var dayMismatch = ServerScoreDayCache(day: "2026-09-22", algorithmVersion: original.algorithmVersion,
            daily: original.daily, nights: original.nights, computedAt: original.computedAt, stale: original.stale, fetchedAt: original.fetchedAt)
        dayMismatch.ownerId = owner; dayMismatch.rawSnapshotJSON = original.rawSnapshotJSON
        XCTAssertTrue(dayMismatch.signalWindows.isEmpty)
        var otherDevice = window(); otherDevice["device_id"] = "other"
        XCTAssertEqual(try snapshot([window(), otherDevice]).signalWindows.count, 1)
        XCTAssertEqual(try snapshot(Array(repeating: window(), count: 2600)).signalWindows.count, 2600)
        XCTAssertTrue(try snapshot(Array(repeating: window(), count: 4097)).signalWindows.isEmpty)
    }
}
