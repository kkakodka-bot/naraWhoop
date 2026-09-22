import XCTest
@testable import StrandDesign

final class CanonicalConsumerLedgerTests: XCTestCase {
    private func ledger(status: String = "available", revision: String? = "result-17",
                        authorization: String? = nil, algorithm: String = "frwhoop-server-1") -> CanonicalConsumerLedger {
        let receipt = CanonicalConsumerLedger.Receipt(family: "recovery", status: status, reason: nil,
            algorithmVersion: algorithm, configurationVersion: "config-1", modelVersion: nil,
            preprocessingVersion: "preprocess-1", qualityVersion: "quality-1", inputRevision: 17,
            resultRevision: revision, computedAt: "2026-09-21T10:00:00Z", observedThrough: "2026-09-21T09:00:00Z",
            freshness: "current", timezoneID: "America/Los_Angeles", manifestHash: nil,
            featureManifestHash: nil, canonicalAuthorization: authorization)
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
        XCTAssertEqual(received.canonicalLedger?.families["recovery"]?.resultRevision, "result-17")
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
        XCTAssertNotEqual(first.families["recovery"], ledger(revision: "result-18").families["recovery"])
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
