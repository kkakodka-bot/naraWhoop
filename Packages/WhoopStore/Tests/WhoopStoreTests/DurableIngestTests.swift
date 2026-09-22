import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class DurableIngestTests: XCTestCase {
    private let scope = DurableIngestScope(environment: "https://fixture.invalid",
        accountID: "11111111-1111-4111-8111-111111111111", deviceID: "strap-a")

    private func store() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.bindAccountOwner(projectURL: scope.environment!, userID: scope.accountID!)
        try await store.upsertDevice(id: scope.deviceID, mac: nil, name: nil)
        return store
    }

    private func receipt(_ identity: RawResourceIdentity, grace: Int = 20,
                         overrideScope: DurableIngestScope? = nil, digest: String? = nil) -> RawDurabilityReceipt {
        RawDurabilityReceipt(scope: overrideScope ?? identity.scope, lane: identity.lane,
            resourceKey: identity.resourceKey, contentSHA256: digest ?? identity.contentSHA256,
            objectKey: "fixture/object", receiptID: "verified-fixture", verifiedAt: 10, retainUntil: grace)
    }

    func testPersistedTrueCannotSkipHoleOrSameSecondRecord() async throws {
        UserDefaults.standard.set(true, forKey: "enableBackfillRangeSkip")
        defer { UserDefaults.standard.removeObject(forKey: "enableBackfillRangeSkip") }
        let s = try await store()
        for (ts, index) in [(100, 1), (90, 2), (100, 3)] {
            _ = try await s.insertAndMarkJobsOwed(
                Streams(ppgWaveform: [PpgWaveformSample(ts: ts, samples: [1, -2], recordIndex: index)]),
                deviceId: scope.deviceID, postOffloadJobKinds: ["rescore", "cloudPush"], note: nil, captureScope: scope)
        }
        let rows = try await s.ppgWaveformSamples(deviceId: scope.deviceID, from: 0, to: 200)
        XCTAssertEqual(rows.count, 3)
        let jobs = try await s.owedJobs()
        XCTAssertEqual(jobs.map(\.kind), ["cloudPush"], "raw-only insert owes upload, not scoring")
    }

    func testQuarantineCapacityRollsBackWholeChunkAndDebt() async throws {
        let s = try await store()
        do {
            _ = try await s.persistSensorQuarantine([[1, 2], [3, 4]], scope: scope, family: "whoop5",
                trim: 12, maxBytes: 3)
            XCTFail("must refuse a partially durable chunk")
        } catch { XCTAssertEqual(error as? DurableIngestError, .capacityExceeded) }
        let rows = try await s.pendingSensorQuarantine(scope: scope)
        let jobs = try await s.owedJobs()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(jobs.isEmpty)
        let inserted = try await s.persistSensorQuarantine([[1, 2]], scope: scope, family: "whoop5", trim: 12, maxBytes: 2)
        let replay = try await s.persistSensorQuarantine([[1, 2]], scope: scope, family: "whoop5", trim: 13, maxBytes: 2)
        XCTAssertEqual(inserted, 1)
        XCTAssertEqual(replay, 0)
    }

    func testQuarantineReceiptsRequireScopeChecksumAndGrace() async throws {
        let s = try await store()
        _ = try await s.persistSensorQuarantine([[1, 2]], scope: scope, family: "whoop5", trim: 12)
        let rows = try await s.pendingSensorQuarantine(scope: scope)
        let identity = try await s.rawResourceIdentity(scope: scope, lane: "sensorQuarantine", resourceKey: rows[0].id)
        let resource = try XCTUnwrap(identity)
        let wrongOwner = DurableIngestScope(environment: scope.environment, accountID: "other", deviceID: scope.deviceID)
        for invalid in [receipt(resource, overrideScope: wrongOwner), receipt(resource, digest: String(repeating: "0", count: 64))] {
            do { try await s.recordRawDurabilityReceipt(invalid); XCTFail("receipt must not associate") }
            catch { XCTAssertEqual(error as? DurableIngestError, .invalidReceipt) }
        }
        let pending = try await s.pruneSensorQuarantine(now: 100)
        XCTAssertEqual(pending, 0)
        try await s.recordRawDurabilityReceipt(receipt(resource))
        let early = try await s.pruneSensorQuarantine(now: 19)
        let expired = try await s.pruneSensorQuarantine(now: 20)
        XCTAssertEqual(early, 0)
        XCTAssertEqual(expired, 1)
    }

    func testQuarantineSurvivesReopenAndNeverAdoptsUnassigned() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("fixture.sqlite").path
        let original = try await WhoopStore(path: path)
        let unassigned = DurableIngestScope.unassigned(deviceID: scope.deviceID)
        _ = try await original.persistSensorQuarantine([[7, 8, 9]], scope: unassigned, family: "whoop5", trim: 88)
        let reopened = try await WhoopStore(path: path)
        let retained = try await reopened.pendingSensorQuarantine(scope: unassigned)
        let hidden = try await reopened.pendingSensorQuarantine(scope: scope)
        XCTAssertEqual(retained.map(\.frame), [Data([7, 8, 9])])
        let archiveID = QuarantineArchiveIdentity(recordID: retained[0].id, family: retained[0].family, trim: retained[0].trim).batchID
        let archived = try await reopened.rawFrames(batchId: archiveID)
        XCTAssertEqual(archived, [[7, 8, 9]], "exact recovery bytes survive a real file-store reopen")
        XCTAssertTrue(hidden.isEmpty)
        do { try await reopened.bindAccountOwner(projectURL: scope.environment!, userID: scope.accountID!); XCTFail("no adoption") }
        catch { XCTAssertEqual(error as? LocalAccountOwnershipError, .unassignedExistingData) }
    }

    func testRawOutboxLegacySyncedFlagCannotAuthorizeRetention() async throws {
        let s = try await store()
        let meta = RawBatchMeta(batchId: "batch", deviceId: scope.deviceID, clockRef: ClockRef(device: 1, wall: 1),
            capturedAt: 1, startTs: 1, endTs: 1, frameCount: 1, byteSize: 3, captureScope: scope)
        try await s.enqueueRawBatch(meta, frames: [[1, 2, 3]])
        try await s.markRawBatchSynced(batchId: "batch", at: 1)
        let held = try await s.pruneRaw(now: 100, keepWindowSeconds: 0, maxUnsyncedBytes: 0)
        XCTAssertEqual(held, 0)
        let identity = try await s.rawResourceIdentity(scope: scope, lane: "rawBatch", resourceKey: "batch")
        try await s.recordRawDurabilityReceipt(receipt(XCTUnwrap(identity), grace: 200))
        let early = try await s.pruneRaw(now: 100, keepWindowSeconds: 0, maxUnsyncedBytes: 0)
        let deleted = try await s.pruneRaw(now: 200, keepWindowSeconds: 0, maxUnsyncedBytes: 0)
        XCTAssertEqual(early, 0)
        XCTAssertEqual(deleted, 1)
    }

    func testPpgAndAuxWithoutReceiptsSurviveCapAndOnlyVerifiedBytesPrune() async throws {
        let s = try await store()
        for ts in 100...103 {
            _ = try await s.insert(Streams(ppgWaveform: [PpgWaveformSample(ts: ts, samples: [ts], recordIndex: 1)],
                v18Aux: [V18AuxSample(ts: ts, statusWord: ts)]), deviceId: scope.deviceID,
                v18AuxRetentionRows: 2, v18AuxPruneEveryRows: 1,
                ppgWaveformRetentionRows: 2, ppgWaveformPruneEveryRows: 1)
        }
        let ppgBefore = try await s.ppgWaveformSamples(deviceId: scope.deviceID, from: 0, to: 200)
        let auxBefore = try await s.v18AuxSamples(deviceId: scope.deviceID, from: 0, to: 200)
        XCTAssertEqual(ppgBefore.map(\.ts), [100, 101, 102, 103])
        XCTAssertEqual(auxBefore.map(\.ts), [100, 101, 102, 103])
        for (lane, key) in [("ppgWaveformSample", "100:1"), ("v18AuxSample", "100:-1")] {
            let identity = try await s.rawResourceIdentity(scope: scope, lane: lane, resourceKey: key)
            try await s.recordRawDurabilityReceipt(receipt(XCTUnwrap(identity)))
        }
        _ = try await s.insert(Streams(ppgWaveform: [PpgWaveformSample(ts: 104, samples: [104], recordIndex: 1)],
            v18Aux: [V18AuxSample(ts: 104, statusWord: 104)]), deviceId: scope.deviceID,
            v18AuxRetentionRows: 2, v18AuxPruneEveryRows: 1,
            ppgWaveformRetentionRows: 2, ppgWaveformPruneEveryRows: 1)
        let ppgAfter = try await s.ppgWaveformSamples(deviceId: scope.deviceID, from: 0, to: 200)
        let auxAfter = try await s.v18AuxSamples(deviceId: scope.deviceID, from: 0, to: 200)
        XCTAssertEqual(ppgAfter.map(\.ts), [101, 102, 103, 104])
        XCTAssertEqual(auxAfter.map(\.ts), [101, 102, 103, 104])
    }

    func testSerialAdoptionCannotLoseConflictingCapturedPayloadOrTransferReceipt() async throws {
        let s = try await store()
        let registry = DeviceRegistryStore(dbQueue: s.registryWriter)
        for id in [scope.deviceID, "serial"] {
            try registry.add(PairedDevice(id: id, brand: "WHOOP", model: "5", sourceKind: .liveBLE,
                capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
            _ = try await s.insert(Streams(ppgWaveform: [PpgWaveformSample(ts: 100,
                samples: id == scope.deviceID ? [1] : [2], recordIndex: 1)]), deviceId: id)
        }
        let identity = try await s.rawResourceIdentity(scope: scope, lane: "ppgWaveformSample", resourceKey: "100:1")
        try await s.recordRawDurabilityReceipt(receipt(XCTUnwrap(identity)))
        XCTAssertThrowsError(try registry.adoptSerialIdentity(from: scope.deviceID, to: "serial")) {
            XCTAssertEqual($0 as? DeviceIdentityMigrationError, .capturedIdentityRequiresExplicitMigration)
        }
        let original = try await s.ppgWaveformSamples(deviceId: scope.deviceID, from: 0, to: 200)
        let target = try await s.ppgWaveformSamples(deviceId: "serial", from: 0, to: 200)
        XCTAssertEqual(original.first?.samples, [1])
        XCTAssertEqual(target.first?.samples, [2])
        try registry.deleteAllData(deviceId: scope.deviceID)
        let sourceLedger = try await s.rawResourceIdentity(scope: scope, lane: "ppgWaveformSample", resourceKey: "100:1")
        let survivingTarget = try await s.ppgWaveformSamples(deviceId: "serial", from: 0, to: 200)
        XCTAssertNil(sourceLedger)
        XCTAssertEqual(survivingTarget.first?.samples, [2])
        let receipts = try await s.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawDurabilityReceipt WHERE deviceId = ?", arguments: [self.scope.deviceID])
        }
        XCTAssertEqual(receipts, 0)
    }
}
