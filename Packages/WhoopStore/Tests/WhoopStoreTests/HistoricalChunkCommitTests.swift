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
        let outcome = try await commit(current)
        let timing = try XCTUnwrap(outcome.durabilityTiming)
        XCTAssertGreaterThanOrEqual(timing.queueWaitMs, 0)
        XCTAssertGreaterThanOrEqual(timing.mutationMs, timing.cursorMutationMs)
        XCTAssertGreaterThanOrEqual(timing.commitReturnMs, 0)
        XCTAssertGreaterThanOrEqual(timing.cursorMutationMs, 0)
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
        let legacyOutcome = try await legacy.insertAndMarkJobsOwed(streams, deviceId: scope.deviceID,
            postOffloadJobKinds: ["rescore", "cloudPush"], note: nil, captureScope: scope)
        XCTAssertNil(legacyOutcome.durabilityTiming, "Non-historical entry points must not emit historical timing")
        _ = try await legacy.persistSensorQuarantine(frames, scope: scope, family: "whoop5",
            trim: 42, clockRef: ref, preserveOccurrences: true)
        try await legacy.setCursor("strap_trim:\(scope.key)", 42)
        XCTAssertEqual(baseline.commits, 3)
    }

    func testTimingSeparatesWriterQueueCursorMutationAndCommitReturnWithoutAnotherTransaction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("timing.sqlite").path
        let current = try await store(path: path)
        let writerEntered = expectation(description: "GRDB writer queue is occupied")
        let commitStarted = expectation(description: "store actor starts historical call")
        let releaseExternal = DispatchSemaphore(value: 0)
        let delays = HistoricalTimingDelays()
        addTeardownBlock {
            releaseExternal.signal()
            try current.registryWriter.close()
            try FileManager.default.removeItem(at: directory)
        }
        try await current.registryWriter.writeWithoutTransaction { db in
            db.add(function: DatabaseFunction("historical_cursor_delay", argumentCount: 0, pure: false) { _ in
                delays.delayCursor()
                return 0
            })
            try db.execute(sql: """
                CREATE TEMP TRIGGER time_historical_cursor BEFORE INSERT ON cursors
                BEGIN SELECT historical_cursor_delay(); END
                """)

        }
        current.registryWriter.add(transactionObserver: delays)
        let holdingWriter = Task.detached {
            try current.registryWriter.writeWithoutTransaction { _ in
                writerEntered.fulfill()
                guard releaseExternal.wait(timeout: .now() + 5) == .success else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
        }
        await fulfillment(of: [writerEntered], timeout: 5)
        let started = ContinuousClock.now
        let chunk = Task {
            try await current.historicalTestTimedCommit(scope: scope, streams: streams,
                frames: frames, ref: ref, started: commitStarted)
        }
        addTeardownBlock {
            releaseExternal.signal()
            _ = try? await holdingWriter.value
            _ = try? await chunk.value
        }
        await fulfillment(of: [commitStarted], timeout: 5)
        // The actor has begun the historical call while its actual GRDB writer is held.
        // This blocks queue admission without changing production DEFERRED transaction mode.
        try await Task.sleep(nanoseconds: 100_000_000)
        releaseExternal.signal()
        try await holdingWriter.value
        let outcome = try await chunk.value
        let elapsed = HistoricalTimingDelays.milliseconds(started.duration(to: .now))
        let timing = try XCTUnwrap(outcome.durabilityTiming)
        XCTAssertGreaterThanOrEqual(timing.queueWaitMs, 25, "Writer contention must precede the mutation interval")
        XCTAssertGreaterThanOrEqual(timing.cursorMutationMs, delays.cursorMs)
        XCTAssertGreaterThanOrEqual(timing.mutationMs, timing.cursorMutationMs)
        XCTAssertGreaterThanOrEqual(timing.commitReturnMs, delays.commitMs)
        XCTAssertLessThanOrEqual(timing.queueWaitMs + timing.mutationMs + timing.commitReturnMs, elapsed)
        XCTAssertEqual(delays.commits, 1, "Instrumentation must not create another durability transaction")
        current.registryWriter.remove(transactionObserver: delays)
        let rows = try await counts(current)
        XCTAssertEqual(rows["hrSample"], 1)
        XCTAssertEqual(rows["sensorQuarantine"], 3)
        let savedCursor = try await current.cursor("strap_trim:\(scope.key)")
        XCTAssertEqual(savedCursor, 42)
        let check = try await current.registryWriter.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check")
        }
        XCTAssertEqual(check, "ok")
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

    func testLiveCaptureRawDecodedAndDebtShareOneCommitWithoutTrimAndSurviveReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("live.sqlite").path
        let current = try await store(path: path)
        let observer = HistoricalCommitObserver()
        current.registryWriter.add(transactionObserver: observer)
        _ = try await current.commitLiveCapture(streams, scope: scope, rawCapture: researchCapture())
        XCTAssertEqual(observer.commits, 1)
        let before = try await counts(current)
        let jobs = try await current.owedJobs()
        XCTAssertEqual(before["hrSample"], 1)
        XCTAssertEqual(before["rawBatch"], 1)
        XCTAssertEqual(before["cursors"], 0, "Live admission never authorizes a historical trim")
        let reopened = try await WhoopStore(path: path)
        let retained = try await reopened.rawFrames(batchId: "research-chunk")
        XCTAssertEqual(retained, researchCapture().frames)
        _ = try await reopened.commitLiveCapture(streams, scope: scope, rawCapture: researchCapture())
        let after = try await counts(reopened)
        let replayJobs = try await reopened.owedJobs()
        XCTAssertEqual(before, after)
        XCTAssertEqual(jobs.map(\.token), replayJobs.map(\.token))
    }

    func testLiveRawWriteFailureRollsBackDecodedRowsAndDebt() async throws {
        let current = try await store()
        let before = try await counts(current)
        try await current.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_live_raw BEFORE INSERT ON rawBatch
                BEGIN SELECT RAISE(ABORT, 'synthetic raw write failure'); END
                """)
        }
        do {
            _ = try await current.commitLiveCapture(streams, scope: scope, rawCapture: researchCapture())
            XCTFail("Partial live commit escaped")
        } catch {}
        let after = try await counts(current)
        XCTAssertEqual(after, before)
        try await current.registryWriter.write { db in try db.execute(sql: "DROP TRIGGER reject_live_raw") }
        _ = try await current.commitLiveCapture(streams, scope: scope, rawCapture: researchCapture())
        let recovered = try await counts(current)
        XCTAssertEqual(recovered["hrSample"], 1)
        XCTAssertEqual(recovered["rawBatch"], 1)
    }

    func testLiveReplayWrongScopeAndChangedBytesCannotMutateExistingRows() async throws {
        let current = try await store()
        _ = try await current.commitLiveCapture(streams, scope: scope, rawCapture: researchCapture())
        let before = try await counts(current)
        let wrong = DurableIngestScope(environment: scope.environment, accountID: "other-owner", deviceID: scope.deviceID)
        for capture in [researchCapture(frames: [[0, 1]]), researchCapture(scope: wrong)] {
            do {
                _ = try await current.commitLiveCapture(Streams(hr: [HRSample(ts: 102, bpm: 61)]),
                    scope: scope, rawCapture: capture)
                XCTFail("Wrong immutable capture accepted")
            } catch { XCTAssertEqual(error as? DurableIngestError, .identityConflict) }
        }
        let after = try await counts(current)
        XCTAssertEqual(after, before)
    }

    private func researchCapture(frames: [[UInt8]] = [[9, 8], [7, 6]],
                                 scope: DurableIngestScope? = nil) -> HistoricalRawCapture {
        let owner = scope ?? self.scope
        return HistoricalRawCapture(meta: RawBatchMeta(batchId: "research-chunk", deviceId: owner.deviceID,
            clockRef: ref, capturedAt: 101, startTs: 100, endTs: 101,
            frameCount: frames.count, byteSize: frames.reduce(0) { $0 + $1.count },
            captureScope: owner), frames: frames)
    }

    @discardableResult
    private func commitResearch(_ store: WhoopStore, capture: HistoricalRawCapture? = nil) async throws -> BackfillInsertOutcome {
        try await store.commitHistoricalChunk(streams, scope: scope, family: "whoop5", trim: 42,
            recoveryFrames: frames, clockRef: ref, postOffloadJobKinds: ["rescore", "cloudPush"],
            rawCapture: capture ?? researchCapture())
    }

    func testResearchRawRowsArchiveDebtAndCursorShareOneCommitAndReplayIdentity() async throws {
        let current = try await store()
        let observer = HistoricalCommitObserver()
        current.registryWriter.add(transactionObserver: observer)
        try await commitResearch(current)
        XCTAssertEqual(observer.commits, 1)
        let original = try await counts(current)
        let jobs = try await current.owedJobs()
        XCTAssertEqual(original["rawBatch"], 4)
        let raw = try await current.rawFrames(batchId: "research-chunk")
        XCTAssertEqual(raw, researchCapture().frames)
        let replay = try await commitResearch(current)
        XCTAssertEqual(replay.insertedHistoricalSensorRows, 0)
        let replayed = try await counts(current)
        let replayJobs = try await current.owedJobs()
        XCTAssertEqual(original, replayed)
        XCTAssertEqual(jobs.map(\.token), replayJobs.map(\.token))
    }

    func testResearchRawFailureRollsBackDecodedRecoveryDebtAndCursor() async throws {
        let current = try await store()
        let before = try await counts(current)
        try await current.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_research BEFORE INSERT ON rawBatch
                WHEN NEW.batchId = 'research-chunk'
                BEGIN SELECT RAISE(ABORT, 'synthetic raw write failure'); END
                """)
        }
        do { try await commitResearch(current); XCTFail("Raw failure authorized ACK") }
        catch {}
        let after = try await counts(current)
        XCTAssertEqual(after, before)
    }

    func testResearchReplayPreservesFirstClockObservationAfterReconnect() async throws {
        let current = try await store()
        try await commitResearch(current)
        let capture = researchCapture()
        let later = HistoricalRawCapture(meta: RawBatchMeta(batchId: capture.meta.batchId,
            deviceId: scope.deviceID, clockRef: ClockRef(device: 999, wall: 999), capturedAt: 999,
            startTs: 998, endTs: 999, frameCount: capture.frames.count, byteSize: capture.meta.byteSize,
            captureScope: scope), frames: capture.frames)
        try await commitResearch(current, capture: later)
        let stored = try await current.registryWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM rawBatch WHERE batchId = 'research-chunk'")
        }
        let row = try XCTUnwrap(stored)
        XCTAssertEqual(row["deviceClockRef"] as Int, ref.device)
        XCTAssertEqual(row["wallClockRef"] as Int, ref.wall)
        XCTAssertEqual(row["capturedAt"] as Int, capture.meta.capturedAt)
        XCTAssertEqual(row["startTs"] as Int, capture.meta.startTs)
        XCTAssertEqual(row["endTs"] as Int, capture.meta.endTs)
    }

    func testResearchRawConflictOrWrongOwnerCannotAdvanceCursor() async throws {
        let current = try await store()
        try await commitResearch(current)
        let before = try await counts(current)
        let wrong = DurableIngestScope(environment: scope.environment, accountID: "other-owner", deviceID: scope.deviceID)
        for capture in [researchCapture(frames: [[9, 8], [5, 4]]), researchCapture(scope: wrong)] {
            do {
                _ = try await current.commitHistoricalChunk(Streams(hr: [HRSample(ts: 101, bpm: 61)]),
                    scope: scope, family: "whoop5", trim: 43, recoveryFrames: [[5, 4]], clockRef: ref,
                    postOffloadJobKinds: ["cloudPush"], rawCapture: capture)
                XCTFail("Conflicting raw identity authorized ACK")
            } catch { XCTAssertEqual(error as? DurableIngestError, .identityConflict) }
            let after = try await counts(current)
            let cursor = try await current.cursor("strap_trim:\(scope.key)")
            XCTAssertEqual(after, before)
            XCTAssertEqual(cursor, 42)
        }
    }

    func testRevocationInsideHistoricalRowWriteRollsBackRawDebtAndCursor() async throws {
        let current = try await store()
        let before = try await counts(current)
        let fence = StoreWriteFence()
        try await current.registryWriter.write { db in
            db.add(function: DatabaseFunction("revoke_historical_owner", argumentCount: 0) { _ in
                fence.invalidate()
                return 0
            })
            try db.execute(sql: """
                CREATE TEMP TRIGGER revoke_historical AFTER INSERT ON hrSample
                BEGIN SELECT revoke_historical_owner(); END
                """)
        }
        try await current.fenceWrites(untilRevoked: fence)
        do { try await commitResearch(current); XCTFail("Revoked historical transaction committed") }
        catch { XCTAssertEqual(error as? StoreWriteFence.Failure, .revoked) }
        let after = try await counts(current)
        XCTAssertEqual(after, before)
    }

    func testExistingLegacyResearchBytesCreateOwnershipAndDebtInSameCommit() async throws {
        let current = try await store()
        let capture = researchCapture()
        try await current.enqueueRawBatch(capture.meta, frames: capture.frames)
        try await current.registryWriter.write { db in
            // Synthetic legacy state before durable ownership/debt was introduced.
            try db.execute(sql: "DELETE FROM ingestRawResource WHERE resourceKey = 'research-chunk'")
            try db.execute(sql: "DELETE FROM syncJob")
        }
        _ = try await current.commitHistoricalChunk(Streams(), scope: scope, family: "whoop5",
            trim: 42, recoveryFrames: [], clockRef: ref, postOffloadJobKinds: [], rawCapture: capture)
        let jobs = try await current.owedJobs()
        let identity = try await current.rawResourceIdentity(scope: scope, lane: "rawBatch", resourceKey: "research-chunk")
        XCTAssertEqual(jobs.map(\.kind), ["cloudPush"])
        XCTAssertNotNil(identity)
    }

    func testPrunedResearchReplayNeedsExactReceiptAndDoesNotRecreateUploadDebt() async throws {
        let current = try await store()
        try await commitResearch(current)
        let saved = try await current.rawResourceIdentity(scope: scope, lane: "rawBatch", resourceKey: "research-chunk")
        let identity = try XCTUnwrap(saved)
        // Direct deletion simulates a damaged/dangling ledger, never a production recovery strategy.
        try await current.registryWriter.write { db in
            try db.execute(sql: "DELETE FROM rawBatch WHERE batchId = 'research-chunk'")
        }
        do { try await commitResearch(current); XCTFail("A dangling ledger is not raw durability") }
        catch { XCTAssertEqual(error as? DurableIngestError, .identityConflict) }
        try await current.recordRawDurabilityReceipt(RawDurabilityReceipt(scope: scope, lane: "rawBatch",
            resourceKey: "research-chunk", contentSHA256: identity.contentSHA256,
            objectKey: "synthetic/object", receiptID: "synthetic-receipt", verifiedAt: 1, retainUntil: 2))
        let jobs = try await current.owedJobs()
        try await commitResearch(current)
        let replayJobs = try await current.owedJobs()
        let raw = try await current.rawFrames(batchId: "research-chunk")
        XCTAssertTrue(raw.isEmpty)
        XCTAssertEqual(jobs.map(\.token), replayJobs.map(\.token))
    }
}

private final class HistoricalTimingDelays: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var cursorDuration = 0.0
    private var commitDuration = 0.0
    private var committed = 0
    var cursorMs: Double { lock.lock(); defer { lock.unlock() }; return cursorDuration }
    var commitMs: Double { lock.lock(); defer { lock.unlock() }; return commitDuration }
    var commits: Int { lock.lock(); defer { lock.unlock() }; return committed }
    func delayCursor() {
        let started = ContinuousClock.now
        Thread.sleep(forTimeInterval: 0.025)
        let elapsed = Self.milliseconds(started.duration(to: .now))
        lock.lock(); cursorDuration = elapsed; lock.unlock()
    }
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() {
        let started = ContinuousClock.now
        Thread.sleep(forTimeInterval: 0.025)
        let elapsed = Self.milliseconds(started.duration(to: .now))
        lock.lock(); commitDuration = elapsed; lock.unlock()
    }
    func databaseDidCommit(_ db: Database) { lock.lock(); committed += 1; lock.unlock() }
    func databaseDidRollback(_ db: Database) {}
    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
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
    func historicalTestTimedCommit(scope: DurableIngestScope, streams: Streams,
                                   frames: [[UInt8]], ref: ClockRef,
                                   started: XCTestExpectation) async throws -> BackfillInsertOutcome {
        started.fulfill()
        return try await commitHistoricalChunk(streams, scope: scope, family: "whoop5",
            trim: 42, recoveryFrames: frames, clockRef: ref,
            postOffloadJobKinds: ["rescore", "cloudPush"])
    }
    func historicalTestStepRevision(_ device: String) -> String {
        stepDataRevision.signature(deviceId: device, from: 0, to: 200)
    }
    func exhaustHistoricalTestRetentionBudgets(_ device: String) {
        v18AuxRowsSincePrune[device] = Self.v18AuxPruneEveryRows
        ppgWaveformRowsSincePrune[device] = Self.ppgWaveformPruneEveryRows
    }
}
