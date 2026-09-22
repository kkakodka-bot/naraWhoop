import XCTest
@testable import WhoopStore

final class ServerMetricOwnershipTests: XCTestCase {
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let device = "22222222-2222-4222-8222-222222222222"
    private let day = "2026-09-21"
    private var scope: ServerMetricOwnership.Scope {
        .init(project: "https://compute.invalid", ownerID: owner, deviceID: device)
    }

    private func cache(feature: String = "hrv", status: String = "available", qualified: Bool = true,
                       revision: Int? = 7, value: Any = 0, reason: String? = nil,
                       day: String? = nil, owner: String? = nil, device: String? = nil) throws -> ServerScoreDayCache {
        var metadata: [String: Any] = ["status": status, "algorithm_version": "frwhoop-physiology-2",
            "device_id": device ?? self.device, "computed_at": "2026-09-21T10:00:00Z"]
        if qualified {
            metadata["canonical_qualification"] = "signed_reference_approval"
            metadata["feature_manifest_hash"] = String(repeating: "f", count: 64)
        }
        metadata["input_revision"] = revision
        metadata["reason"] = reason
        let body: [String: Any] = ["server_scoring": ["schema_version": 2, "user_id": owner ?? self.owner,
            "day": day ?? self.day, "algorithm_version": "per_feature", "features": [feature: metadata],
            "daily": ["hrv_rmssd_ms": value], "nights": [], "stale": status == "stale"]]
        return try ServerScoreCacheCodec.parseSnapshot(JSONSerialization.data(withJSONObject: body),
            day: day ?? self.day, ownerId: owner ?? self.owner)
    }

    func testPartialQualifiedResultOwnsOnlyItsSerializedOutputs() throws {
        var ownership = ServerMetricOwnership(scope: scope)
        XCTAssertTrue(ownership.observe(try cache()))
        XCTAssertTrue(ownership.owns("hrv_rmssd_ms"))
        XCTAssertFalse(ownership.owns("sleep_sessions"))
        XCTAssertFalse(ownership.owns("current_hrv"), "A nightly feature does not prove a current/session consumer")
        XCTAssertFalse(ownership.canRetireDailyKernel)
    }

    func testNullFailureRevocationAndHistoricalNavigationCannotRestartLocalFallback() throws {
        var ownership = ServerMetricOwnership(scope: scope)
        ownership.observe(try cache())
        let prior = ownership
        for (status, qualified, reason) in [("pending", true, "queued"), ("unavailable", true, "failed"),
                                           ("unavailable", false, "unqualified_version")] {
            let missing = try cache(status: status, qualified: qualified, value: NSNull(), reason: reason)
            ownership.observe(missing)
            XCTAssertEqual(ownership, prior)
            let presented = ownership.presentation(missing, day: day)
            let selected = ServerVitalSelection.resolve(.hrv, serverEnabled: false, selectedDay: day,
                overlay: presented, localValue: 99)
            XCTAssertTrue(selected.fromServer)
            XCTAssertNil(selected.value)
            XCTAssertEqual(selected.status, reason)
        }
        let historical = ownership.presentation(nil, day: "2020-01-01")
        XCTAssertNil(ServerVitalSelection.resolve(.hrv, serverEnabled: true, selectedDay: "2020-01-01",
            overlay: historical, localValue: 99).value)
        XCTAssertEqual(ownership, prior)
    }

    func testZeroAndUnownedLegacyMetricRemainDistinct() throws {
        var ownership = ServerMetricOwnership(scope: scope)
        let result = try cache()
        ownership.observe(result)
        let presented = ownership.presentation(result, day: day)
        XCTAssertEqual(ServerVitalSelection.resolve(.hrv, serverEnabled: true, selectedDay: day,
            overlay: presented, localValue: 99).value, 0)
        let sleep = ServerVitalSelection.resolve(.sleep, serverEnabled: true, selectedDay: day,
            overlay: presented, localValue: 480)
        XCTAssertFalse(sleep.fromServer)
        XCTAssertEqual(sleep.value, 480)
    }

    func testScopeAndPublicationEvidenceAreRequiredBeforeClaim() throws {
        var ownership = ServerMetricOwnership(scope: scope)
        XCTAssertFalse(ownership.observe(try cache(qualified: false)))
        XCTAssertFalse(ownership.observe(try cache(revision: nil)))
        XCTAssertFalse(ownership.observe(try cache(owner: "33333333-3333-4333-8333-333333333333")))
        XCTAssertFalse(ownership.observe(try cache(device: "44444444-4444-4444-8444-444444444444")))
        XCTAssertTrue(ownership.metrics.isEmpty)
    }

    func testRestartRestoresOnlyTheSameProjectOwnerAndDevice() throws {
        let suite = "compute-ownership-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = ServerMetricOwnershipStore(defaults: defaults).observe(try cache(), scope: scope)
        let store = ServerMetricOwnershipStore(defaults: defaults)
        XCTAssertEqual(store.load(scope), original)
        for other in [ServerMetricOwnership.Scope(project: "https://other.invalid", ownerID: owner, deviceID: device),
                      .init(project: scope.project, ownerID: "other-owner", deviceID: device),
                      .init(project: scope.project, ownerID: owner, deviceID: "other-device")] {
            XCTAssertTrue(store.load(other).metrics.isEmpty)
        }
        XCTAssertTrue(store.load(scope).owns("hrv_rmssd_ms"))
    }

    func testOlderPublicationCannotRollBackClaim() throws {
        var ownership = ServerMetricOwnership(scope: scope)
        ownership.observe(try cache(revision: 9))
        XCTAssertFalse(ownership.observe(try cache(revision: 8)))
        XCTAssertEqual(ownership.claims["hrv"]?.inputRevision, 9)
    }

    func testReadFailureRetainsStaleRevisionButNeverLocalMissingValue() throws {
        var ownership = ServerMetricOwnership(scope: scope)
        let result = try cache(revision: 9)
        ownership.observe(result)
        let presented = ownership.presentation(result, day: day, readFailed: true)
        XCTAssertTrue(presented?.stale == true)
        XCTAssertEqual(presented?.features["hrv"]?.inputRevision, 9)
        XCTAssertEqual(presented?.readFailure, "server_read_failed")
        let missing = ownership.presentation(nil, day: "2020-01-01", readFailed: true)
        let selected = ServerVitalSelection.resolve(.hrv, serverEnabled: false, selectedDay: "2020-01-01",
            overlay: missing, localValue: 99)
        XCTAssertTrue(selected.fromServer)
        XCTAssertNil(selected.value)
        XCTAssertEqual(selected.status, "server_read_failed")
    }
}
