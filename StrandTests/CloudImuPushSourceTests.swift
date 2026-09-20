import XCTest
import Foundation
import GRDB
import NoopPush
import WhoopStore
#if canImport(CloudUploadHarness)
@testable import CloudUploadHarness
#else
@testable import Strand
#endif

/// Actual canonical files and durable SQLite membership, not a timestamp-only source mock.
struct W5ImuFixture {
    let root: URL
    let scope: AccountScope
    let defaults: UserDefaults
    let suite: String
    let sessions: ImuSessionFileStore
    let continuous: ImuSessionFileStore
    let source: CloudImuPushSource
    let device = "opaque-fixture-strap"
    let ts: Int64 = 1_800_000_000
    var indexDirectory: URL { root.appendingPathComponent("index") }

    init(scope: AccountScope? = nil, segmentBudget: Int = 16) throws {
        self.scope = try scope ?? AccountScope(projectURL: "https://project.example", userID: W5ReceiptFixture.owner)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("w5-imu-" + UUID().uuidString)
        suite = "w5-imu-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        let captured = DurableIngestScope(environment: self.scope.projectURL, accountID: self.scope.userID, deviceID: device)
        sessions = ImuSessionFileStore(directory: root.appendingPathComponent("sessions"), defaultsKey: "sessions", defaults: defaults, captureScope: captured)
        continuous = ImuSessionFileStore(directory: root.appendingPathComponent("continuous"), defaultsKey: "continuous", defaults: defaults, captureScope: captured)
        source = try CloudImuPushSource(scope: self.scope, directory: root.appendingPathComponent("index"), sessionStore: sessions, continuousStore: continuous, segmentBudget: segmentBudget)
    }
    func close(file: StaticString = #filePath, line: UInt = #line) {
        do {
            try source.index.close()
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        } catch { XCTFail("IMU fixture cleanup failed; retained directory: \(error)", file: file, line: line) }
    }
    func register(_ store: ImuSessionFileStore, id: String, at ts: Int64) {
        store.register(id: id, deviceId: device, fromMs: ts * 1000, toMs: (ts + 100) * 1000)
    }
    func append(_ store: ImuSessionFileStore, ts: Int64, seed: Int16) {
        _ = store.append(deviceId: device, ts: ts, columns: [Int16](repeating: seed, count: 600), receivedAtMs: ts * 1000 + 456)
    }
    func populateSameSecond() {
        register(sessions, id: "window-a", at: ts); register(sessions, id: "window-b", at: ts)
        register(continuous, id: "window-live", at: ts)
        append(sessions, ts: ts, seed: 11); append(continuous, ts: ts, seed: 22)
    }
    func batch(_ rows: [ImuPushRecord]) throws -> PushBinaryBatch {
        try PushProtocol.binaryObjectBatch(table: .rawImuSession, sourceId: W5ReceiptFixture.source, deviceId: device,
            startCursor: nil, rows: rows.map { .rawImuSession(.init(rowId: $0.rowId, ts: $0.ts, columns: $0.columns)) }, protocolVersion: PushProtocol.objectVersion)
    }
    func readIndex<T>(_ body: (Database) throws -> T) throws -> T {
        let db = try DatabaseQueue(path: indexDirectory.appendingPathComponent("membership.sqlite").path)
        defer { XCTAssertNoThrow(try db.close()) }
        return try db.read(body)
    }
}

final class CloudImuPushSourceTests: XCTestCase {
    func testFixtureClosesRetainedMembershipHandleBeforeRemovingDirectory() throws {
        let f = try W5ImuFixture(); defer { f.close() }
        f.populateSameSecond()
        let retained = f.source
        XCTAssertEqual(try retained.indexedPushRows(deviceId: f.device, afterRowId: 0, limit: 100).count, 3)
        f.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
        XCTAssertThrowsError(try retained.index.read { try Int.fetchOne($0, sql: "SELECT 1") }) {
            XCTAssertEqual(($0 as? DatabaseError)?.resultCode, .SQLITE_MISUSE)
        }
    }

    /// Set NARA_IMF1_FIXTURE_DIR to a fresh absolute directory to retain the real Swift wire
    /// objects for the Edge receiver tests. No transport, auth, BLE or shared stores are used.
    func testExportActualSwiftImf1FixturesForSessionAndContinuous() async throws {
        let f = try W5ImuFixture()
        defer { f.close() }
        f.register(f.sessions, id: "edge-session", at: f.ts)
        f.register(f.continuous, id: "edge-continuous", at: f.ts)
        for offset in 0..<3 { f.append(f.sessions, ts: f.ts + Int64(offset), seed: Int16(11 + offset)) }
        for offset in 0..<2 { f.append(f.continuous, ts: f.ts + Int64(offset), seed: Int16(21 + offset)) }
        let store = try await WhoopStore(path: f.root.appendingPathComponent("fixture-source.sqlite").path)
        defer { XCTAssertNoThrow(try store.registryWriter.close()) }
        try await store.bindAccountOwner(projectURL: f.scope.projectURL, userID: f.scope.userID)
        try await store.upsertDevice(id: f.device, mac: nil, name: nil)
        let snapshot = CloudPushSnapshot(db: store.registryWriter, imuPushSource: f.source)
        let rows = try await snapshot.binaryRows(table: .rawBatch, deviceId: f.device, afterRowId: 0, limit: 2)
        XCTAssertEqual(rows.count, 2)

        let configured = ProcessInfo.processInfo.environment["NARA_IMF1_FIXTURE_DIR"]
        if let configured {
            guard configured.hasPrefix("/"), configured != "/" else {
                XCTFail("NARA_IMF1_FIXTURE_DIR must name a fresh absolute output directory"); return
            }
        }
        let destination = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? f.root.appendingPathComponent("edge-fixture", isDirectory: true)
        let fm = FileManager.default
        // Never replace evidence from another run. Existing empty parent directories are allowed.
        for name in ["session", "continuous", "fixture.json"] {
            guard !fm.fileExists(atPath: destination.appendingPathComponent(name).path) else {
                throw CocoaError(.fileWriteFileExists)
            }
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var origins = Set<String>()
        var cases: [[String: Any]] = []
        for wireRow in rows {
            guard case .rawBatch(let row) = wireRow else { XCTFail("archive did not use rawBatch"); return }
            let (descriptor, bytes) = try ImuArchiveDescriptor.decode(row)
            XCTAssertTrue(origins.insert(descriptor.origin).inserted)
            XCTAssertEqual(descriptor.ownerNamespace, f.scope.namespace)
            XCTAssertEqual(descriptor.device, f.device)
            let canonicalStore = descriptor.origin == "session" ? f.sessions : f.continuous
            let canonical = try canonicalStore.pushSegmentSnapshot(.init(windowID: descriptor.window,
                deviceID: f.device, bucket: descriptor.bucket))
            XCTAssertEqual(bytes, canonical.archiveBytes, "export exact canonical file bytes, not a row reconstruction")
            XCTAssertEqual(descriptor.recordCount, descriptor.origin == "session" ? 3 : 2)
            XCTAssertEqual(descriptor.members.count, canonical.records.count)
            XCTAssertEqual(descriptor.fileSHA256, PushDurabilityReceipt.sha256(bytes))
            XCTAssertEqual(try descriptor.batchID(), row.batchId)
            let batch = try PushProtocol.binaryObjectBatch(table: .rawBatch, sourceId: W5ReceiptFixture.source,
                deviceId: f.device, startCursor: nil, rows: [wireRow], protocolVersion: PushProtocol.objectVersion)
            let retry = try PushProtocol.binaryObjectBatch(table: .rawBatch, sourceId: W5ReceiptFixture.source,
                deviceId: f.device, startCursor: nil, rows: [wireRow], protocolVersion: PushProtocol.objectVersion)
            XCTAssertEqual(batch.manifestJSON, retry.manifestJSON)
            XCTAssertEqual(batch.payload, retry.payload)
            XCTAssertEqual(batch.contentEncoding, "zstd")
            XCTAssertEqual(batch.payload.prefix(4), Data([0x28, 0xb5, 0x2f, 0xfd]))
            XCTAssertEqual(batch.contentSha256, PushDurabilityReceipt.sha256(try PushBinaryCodec.pack(table: .rawBatch, rows: [wireRow])))
            XCTAssertEqual(batch.sampleCount, 2, "rawBatch contains descriptor and file, not IMU row count")
            let output = destination.appendingPathComponent(descriptor.origin, isDirectory: true)
            try fm.createDirectory(at: output, withIntermediateDirectories: false)
            let exports = ["manifest.json": batch.manifestJSON, "payload.zst": batch.payload,
                           "descriptor.json": try descriptor.encoded(), "source.imus": bytes]
            for (name, data) in exports {
                let path = output.appendingPathComponent(name)
                try data.write(to: path, options: .withoutOverwriting)
                XCTAssertEqual(try Data(contentsOf: path), data)
            }
            cases.append(["origin": descriptor.origin, "objectId": batch.objectId,
                          "batchId": batch.batchId, "archiveBatchId": row.batchId,
                          "recordCount": descriptor.recordCount, "sampleCount": batch.sampleCount,
                          "wireSHA256": PushDurabilityReceipt.sha256(batch.payload),
                          "files": exports.mapValues { PushDurabilityReceipt.sha256($0) }])
        }
        XCTAssertEqual(origins, ["session", "continuous"])
        let metadata: [String: Any] = ["schema": 1, "synthetic": true,
            "producer": "CloudPushSnapshot.binaryRows(rawBatch) -> PushProtocol.binaryObjectBatch",
            "ownerUserId": f.scope.userID, "projectURL": f.scope.projectURL, "ownerNamespace": f.scope.namespace,
            "deviceId": f.device, "sourceId": W5ReceiptFixture.source,
            "cases": cases.sorted { ($0["origin"] as! String) < ($1["origin"] as! String) }]
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("fixture.json"), options: .withoutOverwriting)
    }

    func testArchiveDiscoverySurvivesLossOfWindowRoutingMetadata() async throws {
        let f = try W5ImuFixture(); defer { f.close() }; f.populateSameSecond()
        let before = try f.source.archiveRows(deviceID: f.device, limit: 2)
        f.defaults.removeObject(forKey: "sessions"); f.defaults.removeObject(forKey: "continuous")
        XCTAssertTrue(f.source.pushDeviceIds().isEmpty)
        let store = try await WhoopStore(path: f.root.appendingPathComponent("discovery.sqlite").path)
        defer { XCTAssertNoThrow(try store.registryWriter.close()) }
        let snapshot = CloudPushSnapshot(db: store.registryWriter, imuPushSource: f.source)
        let ids = try await snapshot.knownDeviceIds(capabilities: .init(appendTables: [], mutableTables: [], binaryTables: [.rawBatch]))
        XCTAssertEqual(ids, [f.device], "durable outbox, not transient preferences, owns retry discovery")
        let retry = try f.source.archiveRows(deviceID: f.device, limit: 2)
        XCTAssertEqual(retry.map(\.batchId), before.map(\.batchId))
        XCTAssertEqual(try retry.map { try ImuArchiveDescriptor.decode($0).1 }, try before.map { try ImuArchiveDescriptor.decode($0).1 })
    }

    func testV2MembershipUpgradePreservesRowIDsReceiptsAndScanAcrossRepeatedReopen() throws {
        let f = try W5ImuFixture(); defer { f.close() }; f.populateSameSecond()
        let snapshot = try f.continuous.pushSegmentSnapshot(.init(windowID: "window-live", deviceID: f.device, bucket: f.ts))
        let row = ImuPushRecord(ts: f.ts, columns: try XCTUnwrap(snapshot.records.first).columns, rowId: 42)
        let batch = try f.batch([row])
        let receipt = try JSONEncoder().encode(XCTUnwrap(PushObjectAck.parse(W5ReceiptFixture.bytes(W5ReceiptFixture.object(batch, owner: f.scope.userID)), expectedObjectId: batch.objectId).durabilityReceipt))
        let directory = f.root.appendingPathComponent("pre-archive-index")
        _ = try CloudUploadJournal(directory: directory)
        do {
            let old = try DatabaseQueue(path: directory.appendingPathComponent("membership.sqlite").path)
            defer { XCTAssertNoThrow(try old.close()) }
            var migrations = DatabaseMigrator()
            migrations.registerMigration("v1_owner_and_imu_membership") { db in
                try db.execute(sql: """
                    CREATE TABLE owner (id INTEGER PRIMARY KEY CHECK(id = 1), namespace TEXT NOT NULL);
                    CREATE TABLE member (id INTEGER PRIMARY KEY AUTOINCREMENT, device TEXT NOT NULL,
                      origin TEXT NOT NULL, window TEXT NOT NULL, bucket INTEGER NOT NULL, ts INTEGER NOT NULL,
                      digest TEXT NOT NULL, segmentDigest TEXT NOT NULL, UNIQUE(device, origin, window, bucket, ts, digest));
                    CREATE INDEX member_device ON member(device, id);
                    CREATE TABLE rowReceipt (memberID INTEGER PRIMARY KEY REFERENCES member(id), receipt BLOB NOT NULL);
                    CREATE TABLE scan (device TEXT PRIMARY KEY, lastKey TEXT NOT NULL);
                    """)
            }
            migrations.registerMigration("v2_scan_completion") { try $0.execute(sql: "ALTER TABLE scan ADD COLUMN inProgress INTEGER NOT NULL DEFAULT 0") }
            try migrations.migrate(old)
            try old.write { db in
                try db.execute(sql: "INSERT INTO owner VALUES(1, ?)", arguments: [f.scope.namespace])
                try db.execute(sql: "INSERT INTO member VALUES(42, ?, 'continuous', 'window-live', ?, ?, ?, ?)", arguments: [f.device, f.ts, row.ts, PushDurabilityReceipt.sha256(row.columns), snapshot.resource.contentSHA256])
                try db.execute(sql: "INSERT INTO rowReceipt VALUES(42, ?)", arguments: [receipt])
                try db.execute(sql: "INSERT INTO scan VALUES(?, ?, 1)", arguments: [f.device, "continuous/window-live/\(f.ts)"])
            }
        }
        for _ in 0..<2 {
            let reopened = try CloudImuPushSource(scope: f.scope, directory: directory, sessionStore: f.sessions, continuousStore: f.continuous)
            defer { XCTAssertNoThrow(try reopened.index.close()) }
            XCTAssertEqual(try reopened.indexedPushRecord(deviceId: f.device, rowId: 42)?.columns, row.columns)
            try reopened.index.read { db in
                XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT receipt FROM rowReceipt WHERE memberID = 42"), receipt)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT inProgress FROM scan"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA auto_vacuum"), 0, "older indexes reuse pages without a whole-file VACUUM")
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"), ["v1_owner_and_imu_membership", "v2_scan_completion", "v3_exact_archives_and_compaction", "v4_checkpoint_sweep"])
            }
        }
    }

    func testArchiveQuotaRetainsFilesAndRollsBackUnadmittedIndexWork() throws {
        let f = try W5ImuFixture(); defer { f.close() }; f.populateSameSecond()
        let limited = try CloudImuPushSource(scope: f.scope, directory: f.indexDirectory,
            sessionStore: f.sessions, continuousStore: f.continuous, maximumArchiveBytes: 1)
        defer { XCTAssertNoThrow(try limited.index.close()) }
        XCTAssertThrowsError(try limited.archiveRows(deviceID: f.device, limit: 1)) { XCTAssertEqual($0 as? CloudUploadError, .storageFull) }
        XCTAssertEqual(try f.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM archive") }, 0)
        XCTAssertEqual(try f.continuous.pushSegmentInventory(deviceID: f.device).count, 1)
        XCTAssertEqual(try f.sessions.pushSegmentInventory(deviceID: f.device).count, 2)
        let admitted = try f.source.archiveRows(deviceID: f.device, limit: 2)
        XCTAssertEqual(admitted.count, 2, "lifting the quota retries the same canonical files")
        XCTAssertEqual(try f.readIndex { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") }, 2)
    }

    func testExactArchiveEnvelopeRejectsChangedFileBytesUnderSameIdentity() throws {
        let f = try W5ImuFixture(); defer { f.close() }; f.populateSameSecond()
        let row = try XCTUnwrap(f.source.archiveRows(deviceID: f.device, limit: 1).first)
        let (descriptor, bytes) = try ImuArchiveDescriptor.decode(row)
        var changed = bytes; changed[changed.count - 1] ^= 1
        let corrupted = PushRawBatchRecord(rowId: row.rowId, batchId: row.batchId, capturedAt: row.capturedAt,
            deviceClockRef: row.deviceClockRef, wallClockRef: row.wallClockRef, startTs: row.startTs,
            endTs: row.endTs, frameCount: row.frameCount, byteSize: row.byteSize,
            framesBlob: try ImuArchiveDescriptor.framesBlob(descriptor: descriptor.encoded(), file: changed))
        XCTAssertThrowsError(try ImuArchiveDescriptor.decode(corrupted))
        XCTAssertEqual(try ImuArchiveDescriptor.decode(row).1, bytes)
    }

    func testSameSecondAcrossWindowsAndContinuousHasDistinctDurableRows() throws {
        let f = try W5ImuFixture(); defer { f.close() }; f.populateSameSecond()
        let rows = try f.source.indexedPushRows(deviceId: f.device, afterRowId: 0, limit: 100)
        XCTAssertEqual(rows.count, 3); XCTAssertEqual(Set(rows.map(\.rowId)).count, 3)
        XCTAssertEqual(Set(rows.map(\.ts)), [f.ts]); XCTAssertEqual(Set(rows.map(\.columns)).count, 2)
        let batch = try f.batch(rows)
        XCTAssertEqual(batch.sampleCount, 3, "sampleCount counts one-second wire records, not individual axis samples")
        XCTAssertEqual(batch.endCursor?.rowId, rows.last?.rowId)
        let membership = try f.readIndex { try Row.fetchAll($0, sql: "SELECT origin, window, segmentDigest FROM member ORDER BY id") }
        XCTAssertEqual(Set(membership.map { $0["origin"] as String }), ["continuous", "session"])
        XCTAssertEqual(Set(membership.map { $0["window"] as String }).count, 3)
        XCTAssertTrue(membership.allSatisfy { ($0["segmentDigest"] as String).count == 64 })
    }

    func testReopenRetriesStableIDsAndBackdatedNewWindowRemainsAfterCursor() throws {
        let f = try W5ImuFixture(); defer { f.close() }; f.populateSameSecond()
        let before = try f.source.indexedPushRows(deviceId: f.device, afterRowId: 0, limit: 100)
        let reopened = try CloudImuPushSource(scope: f.scope, directory: f.indexDirectory, sessionStore: f.sessions, continuousStore: f.continuous)
        defer { XCTAssertNoThrow(try reopened.index.close()) }
        XCTAssertEqual(try reopened.indexedPushRows(deviceId: f.device, afterRowId: 0, limit: 100).map(\.rowId), before.map(\.rowId))
        f.register(f.sessions, id: "older-window", at: f.ts - 5000)
        f.append(f.sessions, ts: f.ts - 5000, seed: 33)
        let late = try reopened.indexedPushRows(deviceId: f.device, afterRowId: before.last!.rowId, limit: 100)
        XCTAssertEqual(late.count, 1); XCTAssertEqual(late.first?.ts, f.ts - 5000)
        XCTAssertGreaterThan(try XCTUnwrap(late.first?.rowId), before.last!.rowId)
        XCTAssertTrue(try reopened.indexedPushRows(deviceId: f.device, afterRowId: late.last!.rowId, limit: 100).isEmpty)
    }

    func testAppendToExistingSegmentGetsNewRowWithoutRewritingOldMembership() throws {
        let f = try W5ImuFixture(); defer { f.close() }; f.populateSameSecond()
        let before = try f.source.indexedPushRows(deviceId: f.device, afterRowId: 0, limit: 100)
        f.append(f.continuous, ts: f.ts + 1, seed: 34)
        let next = try f.source.indexedPushRows(deviceId: f.device, afterRowId: before.last!.rowId, limit: 100)
        XCTAssertEqual(next.count, 1); XCTAssertEqual(next.first?.ts, f.ts + 1)
        XCTAssertEqual(try f.source.indexedPushRecord(deviceId: f.device, rowId: before[0].rowId)?.columns, before[0].columns)
    }

    func testBoundedInventoryResumesAfterReopenWithoutPublishingPartialNoData() throws {
        let f = try W5ImuFixture(segmentBudget: 1); defer { f.close() }; f.populateSameSecond()
        XCTAssertThrowsError(try f.source.indexedPushRows(deviceId: f.device, afterRowId: 0, limit: 100)) { XCTAssertEqual($0 as? ImuPushSourceError, .scanPending) }
        let reopened = try CloudImuPushSource(scope: f.scope, directory: f.indexDirectory, sessionStore: f.sessions, continuousStore: f.continuous, segmentBudget: 1)
        defer { XCTAssertNoThrow(try reopened.index.close()) }
        XCTAssertThrowsError(try reopened.indexedPushRows(deviceId: f.device, afterRowId: 0, limit: 100)) { XCTAssertEqual($0 as? ImuPushSourceError, .scanPending) }
        let rows = try reopened.indexedPushRows(deviceId: f.device, afterRowId: 0, limit: 100)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(try f.readIndex { try Int.fetchOne($0, sql: "SELECT inProgress FROM scan") }, 0)
    }

    func testPartialRowReceiptNeverAuthorizesExactFilePrune() throws {
        let f = try W5ImuFixture(); defer { f.close() }; f.populateSameSecond()
        let rows = try f.source.indexedPushRows(deviceId: f.device, afterRowId: 0, limit: 100)
        let selected = [rows[0]], batch = try f.batch(selected)
        let ack = try PushObjectAck.parse(W5ReceiptFixture.bytes(W5ReceiptFixture.object(batch, owner: f.scope.userID)), expectedObjectId: batch.objectId)
        let receipt = try XCTUnwrap(ack.durabilityReceipt)
        try f.source.associatePushReceipt(rows: selected.map { .init(rowId: $0.rowId, ts: $0.ts, columns: $0.columns) }, receipt: receipt, scope: f.scope)
        XCTAssertEqual(try f.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rowReceipt") }, 1)
        XCTAssertFalse(f.continuous.deleteSegment(id: "window-live", bucket: f.ts))
        XCTAssertFalse(f.sessions.deleteSegment(id: "window-a", bucket: f.ts))
        let inventory = try f.continuous.pushSegmentInventory(deviceID: f.device)
        XCTAssertEqual(inventory.count, 1)
        XCTAssertEqual(try f.continuous.pushSegmentSnapshot(inventory[0]).records.count, 1)
        let files = FileManager.default.enumerator(at: f.root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        XCTAssertFalse(files.contains { $0.pathExtension == "receipt" })
    }

    func testReceiptCannotBindChangedColumnsOrAnotherOwner() throws {
        let f = try W5ImuFixture(); defer { f.close() }; f.populateSameSecond()
        let rows = try f.source.indexedPushRows(deviceId: f.device, afterRowId: 0, limit: 100), batch = try f.batch(rows)
        let receipt = try XCTUnwrap(PushObjectAck.parse(W5ReceiptFixture.bytes(W5ReceiptFixture.object(batch, owner: f.scope.userID)), expectedObjectId: batch.objectId).durabilityReceipt)
        let wrong = PushRawImuRecord(rowId: rows[0].rowId, ts: rows[0].ts, columns: Data(repeating: 0, count: 1200))
        XCTAssertThrowsError(try f.source.associatePushReceipt(rows: [wrong], receipt: receipt, scope: f.scope))
        let foreign = try AccountScope(projectURL: f.scope.projectURL, userID: "22222222-2222-4222-8222-222222222222")
        XCTAssertThrowsError(try f.source.associatePushReceipt(rows: [], receipt: receipt, scope: foreign))
        XCTAssertThrowsError(try CloudImuPushSource(scope: foreign, directory: f.indexDirectory, sessionStore: f.sessions, continuousStore: f.continuous))
        let legacy = ImuSessionFileStore(directory: f.root.appendingPathComponent("unassigned"), defaultsKey: "unassigned", defaults: f.defaults)
        XCTAssertThrowsError(try CloudImuPushSource(scope: f.scope, directory: f.root.appendingPathComponent("other-index"), sessionStore: legacy, continuousStore: f.continuous))
        XCTAssertEqual(try f.readIndex { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM rowReceipt") }, 0)
    }

    func testCorruptSegmentAndPendingOnlyFlushFailureDoNotBecomeEmptySuccess() throws {
        let f = try W5ImuFixture(); defer { f.close() }; f.populateSameSecond()
        f.continuous.testFailAppendVerification = true
        XCTAssertThrowsError(try f.source.indexedPushRows(deviceId: f.device, afterRowId: 0, limit: 100))
        f.continuous.testFailAppendVerification = false
        XCTAssertEqual(try f.source.indexedPushRows(deviceId: f.device, afterRowId: 0, limit: 100).count, 3)
        let files = FileManager.default.enumerator(at: f.root.appendingPathComponent("continuous"), includingPropertiesForKeys: nil)!.allObjects as! [URL]
        let file = try XCTUnwrap(files.first { $0.pathExtension == "imus" })
        var data = try Data(contentsOf: file); data.append(0xFF); try data.write(to: file)
        XCTAssertThrowsError(try f.source.indexedPushRecord(deviceId: f.device, rowId: 1))
    }
}
