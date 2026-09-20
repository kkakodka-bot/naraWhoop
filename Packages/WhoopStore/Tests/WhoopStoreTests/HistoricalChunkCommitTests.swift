import Foundation
import GRDB
import XCTest
import WhoopProtocol
@testable import WhoopStore

final class HistoricalChunkCommitTests: XCTestCase {
    private let scope = DurableIngestScope(environment: "https://fixture.invalid",
        accountID: "11111111-1111-4111-8111-111111111111", deviceID: "synthetic-strap")
    private let ref = ClockRef(device: 100, wall: 100)
    private let frames: [[UInt8]] = [[1, 2], [1, 2], [3, 4]]
    private var streams: Streams { Streams(hr: [HRSample(ts: 100, bpm: 60)],
                                           steps: [StepSample(ts: 100, counter: 1)]) }

    private func store(path: String? = nil) async throws -> WhoopStore {
        let store: WhoopStore
        if let path { store = try await WhoopStore(path: path) }
        else { store = try await WhoopStore.inMemory() }
        try await store.bindAccountOwner(projectURL: scope.environment!, userID: scope.accountID!)
        try await store.upsertDevice(id: scope.deviceID, mac: nil, name: nil)
        return store
    }

    @discardableResult
    private func commit(_ store: WhoopStore, decoded: Streams? = nil,
                        recovery: [[UInt8]]? = nil) async throws -> BackfillInsertOutcome {
        try await store.commitHistoricalChunk(decoded ?? streams, scope: scope, family: "whoop5",
            trim: 42, recoveryFrames: recovery ?? frames, clockRef: ref,
            postOffloadJobKinds: ["rescore", "cloudPush"])
    }

    private func counts(_ store: WhoopStore) async throws -> [String: Int] {
        try await store.registryWriter.read { db in
            var values: [String: Int] = [:]
            for table in ["hrSample", "stepSample", "sensorQuarantine", "rawBatch",
                          "ingestRawResource", "syncJob", "cursors", "backfillFrontier"] {
                values[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return values
        }
    }

    func testOrdinaryChunkUsesOneFullDurabilityTransactionAndSurvivesReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("synthetic.sqlite").path
        let current = try await store(path: path)
        let observer = HistoricalCommitObserver()
        current.registryWriter.add(transactionObserver: observer)
        try await commit(current)
        XCTAssertEqual(observer.commits, 1)
        XCTAssertEqual(observer.rollbacks, 0)
        current.registryWriter.remove(transactionObserver: observer)
        let durability = try await current.registryWriter.writeWithoutTransaction { db in
            (try Int.fetchOne(db, sql: "PRAGMA synchronous"),
             try String.fetchOne(db, sql: "PRAGMA journal_mode"),
             try String.fetchOne(db, sql: "PRAGMA quick_check"))
        }
        XCTAssertEqual(durability.0, 2)
        XCTAssertEqual(durability.1, "wal")
        XCTAssertEqual(durability.2, "ok")
        let reopened = try await WhoopStore(path: path)
        let rows = try await counts(reopened)
        XCTAssertEqual(rows["hrSample"], 1)
        XCTAssertEqual(rows["stepSample"], 1)
        XCTAssertEqual(rows["sensorQuarantine"], 3)
        XCTAssertEqual(rows["rawBatch"], 3)
        XCTAssertEqual(rows["syncJob"], 2)
        let cursor = try await reopened.cursor("strap_trim:\(scope.key)")
        XCTAssertEqual(cursor, 42)

        let legacy = try await store()
        let baseline = HistoricalCommitObserver()
        legacy.registryWriter.add(transactionObserver: baseline)
        _ = try await legacy.insertAndMarkJobsOwed(streams, deviceId: scope.deviceID,
            postOffloadJobKinds: ["rescore", "cloudPush"], note: nil, captureScope: scope)
        _ = try await legacy.persistSensorQuarantine(frames, scope: scope, family: "whoop5",
            trim: 42, clockRef: ref, preserveOccurrences: true)
        try await legacy.setCursor("strap_trim:\(scope.key)", 42)
        XCTAssertEqual(baseline.commits, 3)
    }

    func testEveryRequiredWriteFailureRollsBackRowsArchiveDebtFrontiersAndCursor() async throws {
        for table in ["hrSample", "syncJob", "sensorQuarantine", "rawBatch", "cursors"] {
            let current = try await store()
            let before = try await counts(current)
            let revision = await current.historicalTestStepRevision(scope.deviceID)
            try await current.registryWriter.write { db in
                try db.execute(sql: "CREATE TEMP TRIGGER reject_chunk BEFORE INSERT ON \(table) BEGIN SELECT RAISE(ABORT, 'synthetic write failure'); END")
            }
            do { try await commit(current); XCTFail("\(table) failure authorized the chunk") }
            catch {}
            let after = try await counts(current)
            XCTAssertEqual(after, before, table)
            let afterRevision = await current.historicalTestStepRevision(scope.deviceID)
            XCTAssertEqual(afterRevision, revision, "Rollback must not publish a step-cache revision")
        }
    }

    func testActualCommitRejectionRollsBackTheCompleteChunk() async throws {
        let current = try await store()
        let before = try await counts(current)
        let observer = HistoricalCommitObserver(rejectCommit: true)
        current.registryWriter.add(transactionObserver: observer)
        do { try await commit(current); XCTFail("Commit rejection authorized the chunk") }
        catch {}
        XCTAssertEqual(observer.commits, 0)
        XCTAssertEqual(observer.rollbacks, 1)
        current.registryWriter.remove(transactionObserver: observer)
        let after = try await counts(current)
        XCTAssertEqual(after, before)
    }

    func testEmptyDecodedChunkStillPreservesArchiveAndCursor() async throws {
        let current = try await store()
        let outcome = try await commit(current, decoded: Streams())
        XCTAssertEqual(outcome.insertedHistoricalSensorRows, 0)
        let rows = try await counts(current)
        XCTAssertEqual(rows["hrSample"], 0)
        XCTAssertEqual(rows["sensorQuarantine"], 3)
        XCTAssertEqual(rows["rawBatch"], 3)
        let jobs = try await current.owedJobs()
        XCTAssertEqual(jobs.map(\.kind), ["cloudPush"])
        let cursor = try await current.cursor("strap_trim:\(scope.key)")
        XCTAssertEqual(cursor, 42)
    }

    func testEmptyEndStillWritesOneScopedCursor() async throws {
        let current = try await store()
        let observer = HistoricalCommitObserver()
        current.registryWriter.add(transactionObserver: observer)
        try await commit(current, decoded: Streams(), recovery: [])
        XCTAssertEqual(observer.commits, 1)
        let rows = try await counts(current)
        XCTAssertEqual(rows["cursors"], 1)
        XCTAssertEqual(rows["syncJob"], 0)
        XCTAssertEqual(rows["rawBatch"], 0)
    }

    func testReplayPreservesOccurrenceIdentityExactBytesAndExistingDebt() async throws {
        let current = try await store()
        try await commit(current)
        let before = try await counts(current)
        let jobs = try await current.owedJobs()
        let first = try await current.pendingSensorQuarantine(scope: scope)
        let replay = try await commit(current)
        XCTAssertEqual(replay.insertedHistoricalSensorRows, 0)
        let after = try await counts(current)
        let replayJobs = try await current.owedJobs()
        let second = try await current.pendingSensorQuarantine(scope: scope)
        XCTAssertEqual(after, before)
        XCTAssertEqual(second.map(\.id), first.map(\.id))
        XCTAssertEqual(replayJobs.map(\.token), jobs.map(\.token))
        var membership: [Int: [UInt8]] = [:]
        for row in second {
            let identity = QuarantineArchiveIdentity(recordID: row.id, family: row.family, trim: row.trim)
            let ordinal = try XCTUnwrap(identity.ordinal)
            let raw = try await current.rawFrames(batchId: identity.batchID)
            XCTAssertEqual(raw, [[UInt8](row.frame)])
            membership[ordinal] = [UInt8](row.frame)
        }
        XCTAssertEqual((0..<frames.count).compactMap { membership[$0] }, frames)
    }

    func testCapturedOwnerAndExactReceiptIdentityRemainAuthoritative() async throws {
        let current = try await store()
        let wrong = DurableIngestScope(environment: scope.environment, accountID: "different-owner", deviceID: scope.deviceID)
        do {
            _ = try await current.commitHistoricalChunk(Streams(), scope: wrong, family: "whoop5",
                trim: 42, recoveryFrames: [], clockRef: ref, postOffloadJobKinds: [])
            XCTFail("Even an empty END must validate its captured owner")
        } catch { XCTAssertEqual(error as? DurableIngestError, .identityConflict) }
        let wrongCursor = try await current.cursor("strap_trim:\(wrong.key)")
        XCTAssertNil(wrongCursor)
        try await commit(current)
        let rows = try await current.pendingSensorQuarantine(scope: scope)
        let first = try XCTUnwrap(rows.first)
        let key = QuarantineArchiveIdentity(recordID: first.id, family: first.family, trim: first.trim).batchID
        let saved = try await current.rawResourceIdentity(scope: scope, lane: "rawBatch", resourceKey: key)
        let raw = try XCTUnwrap(saved)
        for (owner, digest) in [(wrong, raw.contentSHA256), (scope, String(repeating: "0", count: 64))] {
            let bad = RawDurabilityReceipt(scope: owner, lane: "rawBatch", resourceKey: key,
                contentSHA256: digest, objectKey: "synthetic/object", receiptID: "fixture-receipt", verifiedAt: 1, retainUntil: 2)
            do { try await current.recordRawDurabilityReceipt(bad); XCTFail("Mismatched receipt associated") }
            catch { XCTAssertEqual(error as? DurableIngestError, .invalidReceipt) }
        }
        let held = try await current.pruneSensorQuarantine(now: 3)
        XCTAssertEqual(held, 0)
        try await current.recordRawDurabilityReceipt(RawDurabilityReceipt(scope: scope,
            lane: "rawBatch", resourceKey: key, contentSHA256: raw.contentSHA256,
            objectKey: "synthetic/object", receiptID: "fixture-receipt", verifiedAt: 1, retainUntil: 2))
        let released = try await current.pruneSensorQuarantine(now: 3)
        XCTAssertEqual(released, 1, "An exact parent raw receipt releases only its own member")
    }

    func testDueRetentionCannotAddTransactionsToOrdinaryChunk() async throws {
        let current = try await store()
        await current.exhaustHistoricalTestRetentionBudgets(scope.deviceID)
        let observer = HistoricalCommitObserver()
        current.registryWriter.add(transactionObserver: observer)
        try await commit(current, decoded: Streams(
            ppgWaveform: [PpgWaveformSample(ts: 100, samples: [1, 2], recordIndex: 1)],
            v18Aux: [V18AuxSample(ts: 100, recordIndex: 1, statusWord: 1)]))
        XCTAssertEqual(observer.commits, 1)
    }

    func testCapacityFailureDoesNotPruneReceiptEligibleEvidenceOnCriticalPath() async throws {
        let current = try await store()
        _ = try await current.persistSensorQuarantine([[1, 2]], scope: scope, family: "whoop5", trim: 1, maxBytes: 2)
        let rows = try await current.pendingSensorQuarantine(scope: scope)
        let key = try XCTUnwrap(rows.first?.id)
        let resource = try await current.rawResourceIdentity(scope: scope, lane: "sensorQuarantine", resourceKey: key)
        let identity = try XCTUnwrap(resource)
        try await current.recordRawDurabilityReceipt(RawDurabilityReceipt(scope: scope,
            lane: identity.lane, resourceKey: key, contentSHA256: identity.contentSHA256,
            objectKey: "synthetic/object", receiptID: "fixture-receipt", verifiedAt: 1, retainUntil: 2))
        do {
            try await current.registryWriter.write { db in
                _ = try WhoopStore.persistSensorQuarantine(db, frames: [[3, 4]], scope: self.scope,
                    family: "whoop5", trim: 42, clockRef: self.ref, preserveOccurrences: true,
                    maxBytes: 2, maxRecords: 100, allowPruning: false)
            }
            XCTFail("Capacity must hold the chunk rather than prune inline")
        } catch { XCTAssertEqual(error as? DurableIngestError, .capacityExceeded) }
        let retained = try await current.pendingSensorQuarantine(scope: scope)
        XCTAssertEqual(retained.map(\.id), [key])
        XCTAssertEqual(retained.map(\.frame), [Data([1, 2])])
    }
}

private final class HistoricalCommitObserver: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var committed = 0
    private var rolledBack = 0
    private let rejectCommit: Bool
    init(rejectCommit: Bool = false) { self.rejectCommit = rejectCommit }
    var commits: Int { lock.lock(); defer { lock.unlock() }; return committed }
    var rollbacks: Int { lock.lock(); defer { lock.unlock() }; return rolledBack }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws {
        if rejectCommit { throw CocoaError(.fileWriteOutOfSpace) }
    }
    func databaseDidCommit(_ db: Database) { lock.lock(); committed += 1; lock.unlock() }
    func databaseDidRollback(_ db: Database) { lock.lock(); rolledBack += 1; lock.unlock() }
}

private extension WhoopStore {
    func historicalTestStepRevision(_ device: String) -> String {
        stepDataRevision.signature(deviceId: device, from: 0, to: 200)
    }
    func exhaustHistoricalTestRetentionBudgets(_ device: String) {
        v18AuxRowsSincePrune[device] = Self.v18AuxPruneEveryRows
        ppgWaveformRowsSincePrune[device] = Self.ppgWaveformPruneEveryRows
    }
}
