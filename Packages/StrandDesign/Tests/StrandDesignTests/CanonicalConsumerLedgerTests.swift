import XCTest
@testable import StrandDesign

final class CanonicalConsumerLedgerTests: XCTestCase {
    private func ledger(status: String = "available", revision: String? = "compute:17",
                        authorization: String? = "retained_legacy", algorithm: String = "frwhoop-server-1",
                        manifest: String? = String(repeating: "a", count: 64), expires: String? = nil) -> CanonicalConsumerLedger {
        let receipt = CanonicalConsumerLedger.Receipt(family: "recovery", status: status, reason: nil,
            algorithmVersion: algorithm, configurationVersion: "config-1", modelVersion: nil,
            preprocessingVersion: "preprocess-1", qualityVersion: "quality-1", inputRevision: 17,
            resultRevision: revision, computedAt: "2026-09-21T10:00:00Z", observedThrough: "2026-09-21T09:00:00Z",
            freshness: "current", timezoneID: "America/Los_Angeles", manifestHash: manifest,
            featureManifestHash: nil, canonicalAuthorization: authorization, expiresAt: expires)
        return CanonicalConsumerLedger(project: "https://example.supabase.co", ownerID: UUID().uuidString,
            sourceID: UUID().uuidString, deviceID: UUID().uuidString, window: "2026-09-21", families: ["recovery": receipt])
    }
    private func snapshot(_ ledger: CanonicalConsumerLedger?, charge: Double? = 0) -> WatchScoreSnapshot {
        WatchScoreSnapshot(charge: charge, chargeCalibrating: false, effort: nil, effortCalibrating: false,
            rest: nil, restCalibrating: false, hr: 60, sleepSummary: "", asOf: Date(),
            scoreDay: "2026-09-21", finalHosted: true, canonicalLedger: ledger)
    }
    func testCompleteIdentitySurvivesWatchWireRoundTripAndValidZeroIsAdmitted() throws {
        let sent = snapshot(ledger())
        let received = try JSONDecoder().decode(WatchScoreSnapshot.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(received.canonicalLedger, sent.canonicalLedger)
        XCTAssertEqual(received.charge, 0)
        XCTAssertTrue(received.hasCanonicalAdmission)
        XCTAssertEqual(received.canonicalLedger?.families["recovery"]?.resultRevision, "compute:17")
    }
    func testMissingAndRevokedCannotAdmitAnOldFlattenedValue() {
        for state in ["unsupported", "processing", "revoked", "failed", "unqualified", "insufficient_input", "insufficient_quality", "unavailable"] {
            XCTAssertFalse(snapshot(ledger(status: state), charge: 80).hasCanonicalAdmission, state)
            XCTAssertTrue(snapshot(ledger(status: state), charge: nil).hasCanonicalAdmission, state)
        }
        XCTAssertFalse(snapshot(ledger(revision: nil)).hasCanonicalAdmission)
        XCTAssertFalse(snapshot(ledger(algorithm: "shadow")).hasCanonicalAdmission)
        XCTAssertFalse(snapshot(nil).hasCanonicalAdmission)
        XCTAssertTrue(snapshot(nil, charge: nil).hasCanonicalAdmission)
    }
    func testScopeAndRevisionArePartOfCacheIdentity() {
        let first = ledger()
        XCTAssertNotEqual(first.scopeIdentity, ledger().scopeIdentity)
        XCTAssertNotEqual(first.families["recovery"], ledger(revision: "compute:18").families["recovery"])
    }
    func testAlgorithmNameCannotAuthorizeLegacyReceiptWithoutItsManifestAndAdmission() {
        XCTAssertFalse(snapshot(ledger(authorization: nil)).hasCanonicalAdmission)
        XCTAssertFalse(snapshot(ledger(manifest: nil)).hasCanonicalAdmission)
        XCTAssertFalse(snapshot(ledger(manifest: "not-a-manifest")).hasCanonicalAdmission)
        XCTAssertFalse(snapshot(ledger(revision: "unrelated-snapshot-field")).hasCanonicalAdmission)
    }
    func testPersistedExpiredReceiptCannotReplayAnOldFlattenedWatchValue() throws {
        let sent = snapshot(ledger(expires: "2000-01-01T00:00:00.000Z"), charge: 80)
        let restored = try JSONDecoder().decode(WatchScoreSnapshot.self, from: JSONEncoder().encode(sent))
        XCTAssertEqual(restored.canonicalLedger?.families["recovery"]?.resultRevision, "compute:17")
        XCTAssertEqual(restored.canonicalLedger?.families["recovery"]?.expiresAt, "2000-01-01T00:00:00.000Z")
        XCTAssertFalse(restored.hasCanonicalAdmission)
        XCTAssertTrue(snapshot(ledger(expires: "2000-01-01T00:00:00.000Z"), charge: nil).hasCanonicalAdmission)
    }
    func testExpiryBoundaryAndHistoricalDailyWithoutExpiry() throws {
        let expiry = ISO8601DateFormatter().date(from: "2026-09-21T10:01:00Z")!
        let receipt = try XCTUnwrap(ledger(status: "stale", expires: "2026-09-21T10:01:00Z").families["recovery"])
        XCTAssertTrue(receipt.permitsValue(at: expiry.addingTimeInterval(-0.001)))
        XCTAssertFalse(receipt.permitsValue(at: expiry))
        XCTAssertFalse(receipt.permitsValue(at: expiry.addingTimeInterval(1)))
        XCTAssertTrue(try XCTUnwrap(ledger().families["recovery"]).permitsValue(at: .distantFuture))
    }
    func testReadFailureChangesPublicationIdentityWithoutChangingPhysiologyRevision() throws {
        let current = ledger()
        let failed = CanonicalConsumerLedger(project: current.project, ownerID: current.ownerID,
            sourceID: current.sourceID, deviceID: current.deviceID, window: current.window,
            families: current.families, readState: "failed", cached: true)
        XCTAssertEqual(failed.scopeIdentity, current.scopeIdentity)
        XCTAssertEqual(failed.families, current.families)
        XCTAssertEqual(failed.families["recovery"]?.resultRevision, "result-17")
        XCTAssertNotEqual(failed, current, "Read failure must bypass a glance publication dedup/throttle")
        XCTAssertFalse(failed.permitsRead)
        XCTAssertFalse(snapshot(failed, charge: 0).hasCanonicalAdmission)
        let missing = try JSONDecoder().decode(WatchScoreSnapshot.self,
            from: JSONEncoder().encode(snapshot(failed, charge: nil)))
        XCTAssertTrue(missing.hasCanonicalAdmission)
        XCTAssertEqual(missing.canonicalLedger?.readState, "failed")
        XCTAssertEqual(missing.canonicalLedger?.cached, true)
    }
}
