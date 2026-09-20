import XCTest
import WhoopProtocol
import WhoopStore
import GRDB
import NoopPush
@testable import Strand

@MainActor
final class CaptureDurabilityTests: XCTestCase {
    private final class Store: StoreWriting {
        var failRaw = false
        var failInsert = false
        var inserts: [(String, Streams)] = []
        var attempts: [(RawBatchMeta, [[UInt8]])] = []
        var inserted: (() -> Void)?
        var gate: CheckedContinuation<Void, Never>?
        var pause = false
        var active = 0
        var maximumActive = 0
        func insert(_ streams: Streams, deviceId: String) async throws -> Collector.BankedCounts {
            active += 1; maximumActive = max(active, maximumActive)
            defer { active -= 1 }
            inserted?()
            if pause { await withCheckedContinuation { gate = $0 } }
            if failInsert { throw CocoaError(.fileWriteOutOfSpace) }
            inserts.append((deviceId, streams))
            return (streams.hr.count, streams.rr.count, streams.events.count, 0, 0, 0, 0, 0)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
            attempts.append((meta, frames))
            if failRaw { throw CocoaError(.fileWriteOutOfSpace) }
        }
    }

    private func imu() throws -> ImuSessionFileStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: dir) }
        let suite = "CaptureDurabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ImuSessionFileStore(directory: dir, defaults: defaults)
    }

    private func console() -> [UInt8] { frameFromPayload([0], type: 50, seq: 0, cmd: 0) }
    private func end() -> [UInt8] {
        func le(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        return frameFromPayload(le(1_790_000_000) + [0, 0] + le(0) + le(42) + le(0), type: 49, seq: 0, cmd: 2)
    }

    func testRawFailurePropagatesAndRetryRetainsUUIDScopeClockBytesWithoutReinsertingDecoded() async throws {
        let s = Store(); s.failRaw = true
        var wall = 1_790_000_000
        var failures = 0
        let c = Collector(store: s, deviceId: "old", enableRawCapture: true, now: { wall },
            imuStore: try imu(), onDurabilityFailure: { failures += 1 })
        c.clockRef = ClockRef(device: 100, wall: 200)
        c.ingest(console())
        let first = await c.flush()
        XCTAssertFalse(first)
        XCTAssertEqual(c.bufferedCount, 1)
        XCTAssertEqual(failures, 1)
        wall += 1000; c.deviceId = "new"; c.clockRef = ClockRef(device: 300, wall: 400)
        s.failRaw = false
        let retry = await c.flush()
        XCTAssertTrue(retry)
        XCTAssertEqual(s.inserts.count, 1)
        XCTAssertEqual(s.attempts.count, 2)
        XCTAssertEqual(s.attempts[0].0, s.attempts[1].0)
        XCTAssertEqual(s.attempts[0].1, s.attempts[1].1)
        XCTAssertEqual(s.attempts[1].0.deviceId, "old")
        XCTAssertEqual(c.bufferedCount, 0)
    }

    func testShutdownJoinsInflightFlushFencesIntakeAndDrainsNextAcceptedBatchOnce() async throws {
        let s = Store(); s.pause = true
        let entered = expectation(description: "insert entered")
        s.inserted = { entered.fulfill(); s.inserted = nil }
        var published = 0
        let c = Collector(store: s, deviceId: "old", enableRawCapture: true,
            onBanked: { _ in published += 1 }, imuStore: try imu())
        c.clockRef = ClockRef(device: 100, wall: 100)
        c.ingest(console())
        let first = Task { await c.flush() }
        await fulfillment(of: [entered], timeout: 2)
        c.ingest(console())
        c.shutdownForAccountChange()
        XCTAssertFalse(c.ingest(console()))
        c.ingestStandardHR(hr: 70, rr: [800], at: 100)
        let drain = Task { await c.drainForShutdown() }
        s.pause = false; s.gate?.resume(); s.gate = nil
        let firstResult = await first.value
        let drained = await drain.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(drained)
        XCTAssertEqual(s.maximumActive, 1)
        XCTAssertEqual(s.inserts.count, 2)
        XCTAssertEqual(s.attempts.count, 2)
        XCTAssertEqual(published, 0)
        XCTAssertEqual(c.bufferedCount, 0)
    }

    func testPreclockShutdownArchivesWithoutInventingDecodedTimestamps() async throws {
        let s = Store()
        let c = Collector(store: s, deviceId: "old", now: { 1_790_000_000 }, imuStore: try imu())
        c.ingest(frameFromPayload([4, 5], type: 99, seq: 0, cmd: 0))
        let drained = await c.drainForShutdown()
        XCTAssertTrue(drained)
        XCTAssertTrue(s.inserts[0].1.isEmpty)
        XCTAssertEqual(s.attempts.count, 1)
        XCTAssertEqual(s.attempts[0].0.startTs, 1_790_000_000)
        XCTAssertEqual(s.attempts[0].0.endTs, 1_790_000_001)
    }

    func testCapacityRejectsNewIntakeInsteadOfEvictingAcceptedPreclockFrames() async throws {
        let s = Store()
        var failures = 0
        let c = Collector(store: s, deviceId: "old", policy: .init(maxFrames: 100, maxInterval: 100, maxPreClockFrames: 2),
            imuStore: try imu(), onDurabilityFailure: { failures += 1 })
        let first = frameFromPayload([1], type: 99, seq: 0, cmd: 0)
        let second = frameFromPayload([2], type: 99, seq: 1, cmd: 0)
        XCTAssertTrue(c.ingest(first))
        XCTAssertTrue(c.ingest(second))
        XCTAssertFalse(c.ingest(console()))
        XCTAssertEqual(failures, 1)
        let drained = await c.drainForShutdown()
        XCTAssertTrue(drained)
        XCTAssertEqual(s.attempts.flatMap { $0.1 }, [first, second])
    }

    func testStandardShutdownWritesOldScopeAndDurableUploadDebt() async throws {
        let s = try await WhoopStore.inMemory()
        let scope = DurableIngestScope(environment: "https://fixture.invalid",
            accountID: "11111111-1111-4111-8111-111111111111", deviceID: "old")
        try await s.bindAccountOwner(projectURL: scope.environment!, userID: scope.accountID!)
        try await s.upsertDevice(id: scope.deviceID, mac: nil, name: nil)
        let c = Collector(store: s, deviceId: scope.deviceID, imuStore: try imu(), captureScope: scope)
        c.ingestStandardHR(hr: 70, rr: [900], family: .whoop5, at: 1_790_000_000)
        let drained = await c.drainForShutdown()
        XCTAssertTrue(drained)
        let rows = try await s.hrSamples(deviceId: scope.deviceID, from: 1_790_000_000, to: 1_790_000_001, limit: 10)
        let debt = try await s.owedJobs()
        XCTAssertEqual(rows.map(\.bpm), [70])
        XCTAssertTrue(debt.contains { $0.kind == "cloudPush" })
    }

    func testStandardDrainReportsFailureAndRetainsEveryCapturedDevice() async throws {
        let s = Store(); s.failInsert = true
        let c = Collector(store: s, deviceId: "a", imuStore: try imu())
        c.ingestStandardHR(hr: 70, rr: [], at: 100)
        c.deviceId = "b"
        c.ingestStandardHR(hr: 80, rr: [], at: 101)
        let failed = await c.drainForShutdown()
        XCTAssertFalse(failed)
        s.failInsert = false
        let retried = await c.drainForShutdown()
        XCTAssertTrue(retried)
        XCTAssertEqual(s.inserts.map { $0.0 }, ["a", "b"])
        XCTAssertEqual(s.inserts.map { $0.1.hr[0].bpm }, [70, 80])
    }

    func testUnknownDeepAndPlausibilityDiscardedHistoryDurableBeforeACKConsoleExcluded() async throws {
        let s = try await WhoopStore.inMemory()
        let scope = DurableIngestScope.unassigned(deviceID: "strap")
        let frames = [frameFromPayload([1, 2], type: 99, seq: 0, cmd: 0),
                      frameFromPayload([3, 4], type: 52, seq: 1, cmd: 0),
                      frameFromPayload([5, 6], type: 47, seq: 2, cmd: 0)]
        let acked = expectation(description: "durable before ack")
        let b = Backfiller(store: s, deviceId: "strap", ackTrim: { _, _ in
            do {
                let rows = try await s.pendingSensorQuarantine(scope: scope)
                XCTAssertEqual(Set(rows.map(\.frame)), Set(frames.map { Data($0) }))
                for row in rows {
                    let id = QuarantineArchiveIdentity(recordID: row.id, family: row.family, trim: row.trim).batchID
                    let raw = try await s.rawFrames(batchId: id)
                    XCTAssertEqual(raw, [[UInt8](row.frame)])
                }
                XCTAssertNotNil(CaptureJobTrace.correlation)
            } catch { XCTFail("\(error)") }
            acked.fulfill()
        }, extract: { _, _, _, _, _ in Streams() })
        b.begin(family: .whoop4)
        for frame in frames + [console()] { await b.ingest(frame) }
        await b.ingest(end())
        await fulfillment(of: [acked], timeout: 2)
        XCTAssertFalse(b.persistStalled)
    }

    func testConflictingAuxiliaryProjectionIsArchivedWithoutACKOrOverwritingOriginal() async throws {
        let s = try await WhoopStore.inMemory()
        try await s.registryWriter.write { db in
            if !(try db.columns(in: "v18AuxSample")).contains(where: { $0.name == "resourceKey" }) {
                try WhoopStore.installV18AuxIdentitySchema(db)
            }
        }
        let original = V18AuxSample(ts: 1_790_000_000, recordIndex: 1, statusWord: 7)
        _ = try await s.insert(Streams(v18Aux: [original]), deviceId: "strap")
        let frame = frameFromPayload([3, 4], type: 52, seq: 1, cmd: 0)
        var ackCount = 0
        let b = Backfiller(store: s, deviceId: "strap", ackTrim: { _, _ in
            await MainActor.run { ackCount += 1 }
        }, extract: { _, _, _, _, _ in
            Streams(v18Aux: [V18AuxSample(ts: 1_790_000_000, recordIndex: 1, statusWord: 8)])
        })
        b.begin(family: .whoop4)
        await b.ingest(frame)
        await b.ingest(end())
        await b.ingest(end())
        XCTAssertTrue(b.persistStalled)
        XCTAssertEqual(ackCount, 0)
        let kept = try await s.v18AuxSamples(deviceId: "strap", from: 1_790_000_000, to: 1_790_000_000)
        XCTAssertEqual(kept, [original])
        let quarantine = try await s.pendingSensorQuarantine(scope: .unassigned(deviceID: "strap"))
        XCTAssertEqual(quarantine.map(\.frame), [Data(frame)])
        let row = try XCTUnwrap(quarantine.first)
        let archiveID = QuarantineArchiveIdentity(recordID: row.id, family: row.family, trim: row.trim).batchID
        let archived = try await s.rawFrames(batchId: archiveID)
        XCTAssertEqual(archived, [frame])
    }

    func testArchiveOutboxFailureHoldsACKAndLaterEmptyEND() async throws {
        let s = try await WhoopStore.inMemory()
        try await s.registryWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_archive BEFORE INSERT ON rawBatch BEGIN SELECT RAISE(ABORT, 'fixture'); END")
        }
        var ackCount = 0
        let b = Backfiller(store: s, deviceId: "strap", ackTrim: { _, _ in await MainActor.run { ackCount += 1 } })
        b.begin(family: .whoop4)
        await b.ingest(frameFromPayload([1, 2], type: 52, seq: 0, cmd: 0))
        await b.ingest(end())
        await b.ingest(end())
        XCTAssertTrue(b.persistStalled)
        XCTAssertEqual(ackCount, 0)
        let rows = try await s.pendingSensorQuarantine(scope: .unassigned(deviceID: "strap"))
        XCTAssertTrue(rows.isEmpty)
    }

    func testInvalidStoredQuarantineTrimHoldsACKAndPreservesOriginalBytes() async throws {
        for invalid in [Int64(-1), Int64(UInt32.max) + 1] {
            let s = try await WhoopStore.inMemory()
            let scope = DurableIngestScope.unassigned(deviceID: "strap")
            let frame = frameFromPayload([1, 2], type: 52, seq: 0, cmd: 0)
            try await s.persistSensorQuarantine([frame], scope: scope, family: "whoop4", trim: 42,
                preserveOccurrences: true)
            let records = try await s.pendingSensorQuarantine(scope: scope)
            let record = try XCTUnwrap(records.first)
            let archiveID = QuarantineArchiveIdentity(recordID: record.id, family: record.family, trim: record.trim).batchID
            try await s.registryWriter.write { db in
                try db.execute(sql: "UPDATE sensorQuarantine SET trim = ?", arguments: [invalid])
            }
            var ackCount = 0
            let b = Backfiller(store: s, deviceId: "strap", ackTrim: { _, _ in
                await MainActor.run { ackCount += 1 }
            }, extract: { _, _, _, _, _ in Streams() })
            b.begin(family: .whoop4)
            await b.ingest(frame)
            await b.ingest(end())
            await b.ingest(end())
            XCTAssertTrue(b.persistStalled)
            XCTAssertEqual(ackCount, 0)
            try await s.registryWriter.read { db in
                let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM sensorQuarantine"))
                XCTAssertEqual(row["id"] as String, record.id)
                XCTAssertEqual(row["trim"] as Int64, invalid)
                XCTAssertEqual(row["frame"] as Data, Data(frame))
            }
            let archived = try await s.rawFrames(batchId: archiveID)
            XCTAssertEqual(archived, [frame])
        }
    }

    func testQuarantineUsesUnchangedRawBatchCodecAndRetryStable12And13Manifests() async throws {
        let s = try await WhoopStore.inMemory()
        let scope = DurableIngestScope.unassigned(deviceID: "strap")
        try await s.persistSensorQuarantine([[0, 255, 2]], scope: scope, family: "whoop5", trim: 7, preserveOccurrences: true)
        let row = try await s.registryWriter.read { db in
            try XCTUnwrap(Row.fetchOne(db, sql: "SELECT rowid AS localRowID, * FROM rawBatch"))
        }
        let record = PushRawBatchRecord(rowId: row["localRowID"], batchId: row["batchId"],
            capturedAt: row["capturedAt"], deviceClockRef: row["deviceClockRef"], wallClockRef: row["wallClockRef"],
            startTs: row["startTs"], endTs: row["endTs"], frameCount: row["frameCount"],
            byteSize: row["byteSize"], framesBlob: row["framesBlob"])
        let packed = try PushBinaryCodec.pack(table: .rawBatch, rows: [.rawBatch(record)])
        XCTAssertEqual(Data(packed.suffix(record.framesBlob.count)), record.framesBlob)
        XCTAssertNotNil(packed.range(of: Data(record.batchId.utf8)))
        XCTAssertNotNil(QuarantineArchiveIdentity(batchID: record.batchId)?.ordinal)
        for version in [PushProtocol.objectVersion, PushProtocol.identityObjectVersion] {
            func assemble() throws -> PushBinaryBatch {
                try PushProtocol.binaryObjectBatch(table: .rawBatch, sourceId: "11111111-1111-4111-8111-111111111111",
                    deviceId: scope.deviceID, startCursor: nil, rows: [.rawBatch(record)], protocolVersion: version)
            }
            let first = try assemble()
            let retry = try assemble()
            XCTAssertEqual(first.manifestJSON, retry.manifestJSON)
            XCTAssertEqual(first.payload, retry.payload)
            XCTAssertEqual(first.endTs - first.startTs, 1)
        }
    }
}
