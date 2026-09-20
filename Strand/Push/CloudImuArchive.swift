import Foundation
import Compression
import GRDB
import NoopPush
import WhoopStore

protocol ImuExactArchiveSource: ImuSessionPushSource {
    func archiveDeviceIDs() throws -> Set<String>
    func archiveRows(deviceID: String, limit: Int) throws -> [PushRawBatchRecord]
    func associateArchive(_ row: PushRawBatchRecord, receipt: PushDurabilityReceipt, scope: AccountScope) throws
    func checkArchiveCommit(_ commit: PushSourceCommit, scope: AccountScope) throws
    func sourceProgressApplied(_ commit: PushSourceCommit, scope: AccountScope) throws
    func sourceCleanupCompleted(_ commit: PushSourceCommit, scope: AccountScope) throws
}

/// Existing rawBatch framing, explicitly tagged as a file archive, never a synthetic BLE packet.
struct ImuArchiveDescriptor: Codable, Equatable {
    struct Member: Codable, Equatable { let rowID, ts: Int64; let sha256: String }
    let version: Int
    let kind, ownerNamespace, device, origin, window: String
    let bucket, windowFrom: Int64
    let windowTo: Int64?
    let fileSHA256: String
    let fileBytes, recordCount: Int
    let previousArchive: String?
    let prefixBytes, prefixRecords: Int
    let prefixSHA256: String?
    let members: [Member]

    func encoded() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(self) }
    func batchID() throws -> String { "imf1.\(PushDurabilityReceipt.sha256(try encoded())).\(fileSHA256)" }
    static func owns(_ id: String) -> Bool { id.hasPrefix("imf1.") }

    static func framesBlob(descriptor: Data, file: Data) throws -> Data {
        var packed = Data()
        func u32(_ value: Int) { var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { packed.append(contentsOf: $0) } }
        u32(2); u32(descriptor.count); packed.append(descriptor); u32(file.count); packed.append(file)
        var output = Data(count: packed.count * 2 + 64)
        let count = output.withUnsafeMutableBytes { dst in packed.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        } }
        guard count > 0 else { throw ImuPushSourceError.corruptSegment }
        output.count = count
        var length = UInt32(packed.count).littleEndian
        var blob = withUnsafeBytes(of: &length) { Data($0) }; blob.append(output); return blob
    }

    /// Strict reversible envelope decoder used to verify source membership before receipt adoption.
    static func decode(_ row: PushRawBatchRecord) throws -> (Self, Data) {
        let blob = row.framesBlob
        guard blob.count >= 4, row.frameCount == 2 else { throw CloudUploadError.invalidReceipt }
        let n = blob.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        guard n > 12, n <= 9 * 1_048_576 else { throw CloudUploadError.invalidReceipt }
        var packed = Data(count: n)
        let decoded = packed.withUnsafeMutableBytes { dst in blob.dropFirst(4).withUnsafeBytes { src in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, n,
                src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        } }
        guard decoded == n else { throw CloudUploadError.invalidReceipt }
        var offset = 0
        func u32() throws -> Int {
            guard offset + 4 <= packed.count else { throw CloudUploadError.invalidReceipt }
            defer { offset += 4 }
            return packed[offset..<offset + 4].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        }
        guard try u32() == 2 else { throw CloudUploadError.invalidReceipt }
        let descriptorLength = try u32()
        guard descriptorLength <= 512 * 1024, offset + descriptorLength <= packed.count else { throw CloudUploadError.invalidReceipt }
        let descriptor = try JSONDecoder().decode(Self.self, from: packed[offset..<offset + descriptorLength]); offset += descriptorLength
        let fileLength = try u32()
        guard offset + fileLength == packed.count else { throw CloudUploadError.invalidReceipt }
        let file = Data(packed[offset...])
        guard descriptor.version == 1, descriptor.kind == "noop.imus.archive", try descriptor.batchID() == row.batchId,
              descriptor.fileBytes == file.count, descriptor.fileSHA256 == PushDurabilityReceipt.sha256(file),
              descriptor.bucket >= 0, descriptor.bucket <= Int64.max - ImuSessionFileStore.segmentSeconds,
              (0...1800).contains(descriptor.recordCount), descriptor.members.count <= 1800,
              descriptor.prefixRecords >= 0, descriptor.prefixRecords <= descriptor.recordCount,
              descriptor.prefixBytes >= 0, descriptor.prefixBytes <= file.count,
              ["session", "continuous"].contains(descriptor.origin),
              row.byteSize == descriptorLength + file.count, row.startTs == descriptor.bucket,
              row.endTs == descriptor.bucket + ImuSessionFileStore.segmentSeconds else { throw CloudUploadError.invalidReceipt }
        return (descriptor, file)
    }
}

extension CloudImuPushSource: ImuExactArchiveSource {
    func archiveDeviceIDs() throws -> Set<String> {
        isolation.lock(); defer { isolation.unlock() }
        // Immutable outbox discovery cannot depend on mutable window-routing preferences.
        return try index.read { db in
            Set(try String.fetchAll(db, sql: "SELECT device FROM archive UNION SELECT device FROM member UNION SELECT device FROM segmentCheckpoint"))
        }
    }

    static func addArchiveMigration(to migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3_exact_archives_and_compaction") { db in
            try db.execute(sql: """
                CREATE TABLE archive (
                  id INTEGER PRIMARY KEY AUTOINCREMENT, batchID TEXT UNIQUE NOT NULL,
                  device TEXT NOT NULL, origin TEXT NOT NULL, window TEXT NOT NULL, bucket INTEGER NOT NULL,
                  descriptor BLOB NOT NULL, bytes BLOB, receipt BLOB,
                  committed INTEGER NOT NULL DEFAULT 0, cleaned INTEGER NOT NULL DEFAULT 0,
                  compacted INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX archive_pending ON archive(device, committed, id);
                CREATE TABLE archiveMember (archiveID INTEGER NOT NULL, memberID INTEGER NOT NULL,
                  PRIMARY KEY(archiveID, memberID));
                CREATE TABLE segmentCheckpoint (
                  device TEXT NOT NULL, origin TEXT NOT NULL, window TEXT NOT NULL, bucket INTEGER NOT NULL,
                  batchID TEXT NOT NULL, bytes INTEGER NOT NULL, records INTEGER NOT NULL, digest TEXT NOT NULL,
                  receipt BLOB NOT NULL, sidecarPending INTEGER NOT NULL DEFAULT 1,
                  PRIMARY KEY(device, origin, window, bucket));
                CREATE TABLE progressAnchor (device TEXT PRIMARY KEY, rowID INTEGER NOT NULL,
                  ts INTEGER NOT NULL, columns BLOB NOT NULL);
                CREATE TABLE archiveScan (device TEXT PRIMARY KEY, lastKey TEXT NOT NULL);
                """)
        }
        migrator.registerMigration("v4_checkpoint_sweep") { db in
            try db.execute(sql: "CREATE TABLE maintenanceCursor (id INTEGER PRIMARY KEY, afterRow INTEGER NOT NULL); INSERT INTO maintenanceCursor VALUES(1, 0)")
        }
    }

    func anchor(deviceID: String, rowID: Int64) throws -> ImuPushRecord? {
        try index.read { db in
            guard let r = try Row.fetchOne(db, sql: "SELECT * FROM progressAnchor WHERE device = ? AND rowID = ?", arguments: [deviceID, rowID]) else { return nil }
            return .init(ts: r["ts"], columns: r["columns"], rowId: r["rowID"])
        }
    }

    func indexSegment(_ db: Database, origin: String, segment: ImuPushSegment, snapshot: ImuPushSegmentSnapshot) throws {
        let prefix = try Row.fetchOne(db, sql: "SELECT * FROM segmentCheckpoint WHERE device = ? AND origin = ? AND window = ? AND bucket = ?",
            arguments: [segment.deviceID, origin, segment.windowID, segment.bucket])
        let count: Int = prefix?["records"] ?? 0
        if let prefix {
            let length: Int = prefix["bytes"]
            guard length >= 24, length <= snapshot.archiveBytes.count, count >= 0, count <= snapshot.records.count,
                  PushDurabilityReceipt.sha256(Data(snapshot.archiveBytes.prefix(length))) == (prefix["digest"] as String) else { throw ImuPushSourceError.corruptSegment }
        }
        for record in snapshot.records.dropFirst(count) {
            try db.execute(sql: """
                INSERT INTO member(device, origin, window, bucket, ts, digest, segmentDigest)
                SELECT ?, ?, ?, ?, ?, ?, ? WHERE NOT EXISTS
                  (SELECT 1 FROM member WHERE device = ? AND origin = ? AND window = ? AND bucket = ? AND ts = ? AND digest = ?)
                """, arguments: [segment.deviceID, origin, segment.windowID, segment.bucket, record.ts,
                    PushDurabilityReceipt.sha256(record.columns), snapshot.resource.contentSHA256,
                    segment.deviceID, origin, segment.windowID, segment.bucket, record.ts, PushDurabilityReceipt.sha256(record.columns)])
        }
    }

    func archiveRows(deviceID: String, limit: Int) throws -> [PushRawBatchRecord] {
        isolation.lock(); defer { isolation.unlock() }
        guard limit > 0, limit <= 2 else { throw ImuPushSourceError.membershipUnavailable }
        // Production source selection follows committer.recover(), so no unsettled source debt
        // can still depend on a removed checkpoint. Never run this sweep inside a commit hook.
        try reclaimMissingCheckpoints()
        try maintainArchives()
        func pending() throws -> [Row] { try index.read { try Row.fetchAll($0, sql: "SELECT * FROM archive WHERE device = ? AND committed = 0 ORDER BY id LIMIT ?", arguments: [deviceID, limit]) } }
        var rows = try pending()
        if rows.count < limit {
            let all = try stores.sorted { $0.key < $1.key }.flatMap { origin, store in
                try store.pushSegmentInventory(deviceID: deviceID).map { (origin, $0) }
            }.sorted { "\($0.0)/\($0.1.windowID)/\($0.1.bucket)" < "\($1.0)/\($1.1.windowID)/\($1.1.bucket)" }
            let last = try index.read { try String.fetchOne($0, sql: "SELECT lastKey FROM archiveScan WHERE device = ?", arguments: [deviceID]) } ?? ""
            let tail = all.filter { "\($0.0)/\($0.1.windowID)/\($0.1.bucket)" > last }
            let remaining = tail.isEmpty ? all : tail
            for (origin, segment) in remaining.prefix(segmentBudget) {
                try prepareArchive(origin: origin, segment: segment)
                try index.write { try $0.execute(sql: "INSERT INTO archiveScan VALUES(?, ?) ON CONFLICT(device) DO UPDATE SET lastKey = excluded.lastKey",
                    arguments: [deviceID, "\(origin)/\(segment.windowID)/\(segment.bucket)"]) }
            }
            rows = try pending()
            if rows.count < limit && remaining.count > segmentBudget { throw ImuPushSourceError.scanPending }
        }
        return try rows.map(archiveRecord)
    }

    private func prepareArchive(origin: String, segment: ImuPushSegment) throws {
        let occupied = try index.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM archive WHERE device = ? AND origin = ? AND window = ? AND bucket = ?)",
            arguments: [segment.deviceID, origin, segment.windowID, segment.bucket]) } ?? false
        guard !occupied else { return }
        guard let store = stores[origin] else { throw ImuPushSourceError.membershipUnavailable }
        let snapshot = try store.pushSegmentSnapshot(segment)
        try index.write { db in
            try indexSegment(db, origin: origin, segment: segment, snapshot: snapshot)
            let prefix = try Row.fetchOne(db, sql: "SELECT * FROM segmentCheckpoint WHERE device = ? AND origin = ? AND window = ? AND bucket = ?",
                arguments: [segment.deviceID, origin, segment.windowID, segment.bucket])
            if (prefix?["digest"] as String?) == snapshot.resource.contentSHA256 { return }
            let members = try Row.fetchAll(db, sql: "SELECT id, ts, digest FROM member WHERE device = ? AND origin = ? AND window = ? AND bucket = ? ORDER BY id",
                arguments: [segment.deviceID, origin, segment.windowID, segment.bucket])
            let prefixRecords: Int = prefix?["records"] ?? 0
            let expected = Dictionary(uniqueKeysWithValues: snapshot.records.dropFirst(prefixRecords).map { ($0.ts, PushDurabilityReceipt.sha256($0.columns)) })
            guard members.count == expected.count, members.allSatisfy({ expected[$0["ts"] as Int64] == ($0["digest"] as String) }) else { throw ImuPushSourceError.corruptSegment }
            let descriptor = ImuArchiveDescriptor(version: 1, kind: "noop.imus.archive", ownerNamespace: scope.namespace,
                device: segment.deviceID, origin: origin, window: segment.windowID, bucket: segment.bucket,
                windowFrom: snapshot.windowFrom, windowTo: snapshot.windowTo, fileSHA256: snapshot.resource.contentSHA256,
                fileBytes: snapshot.archiveBytes.count, recordCount: snapshot.records.count,
                previousArchive: prefix?["batchID"], prefixBytes: prefix?["bytes"] ?? 0, prefixRecords: prefix?["records"] ?? 0,
                prefixSHA256: prefix?["digest"], members: members.map { .init(rowID: $0["id"], ts: $0["ts"], sha256: $0["digest"]) })
            let used = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(length(bytes) + length(descriptor)), 0) FROM archive") ?? 0
            let encoded = try descriptor.encoded()
            guard encoded.count <= 512 * 1024, snapshot.archiveBytes.count + encoded.count <= maximumArchiveBytes - used else { throw CloudUploadError.storageFull }
            try db.execute(sql: "INSERT INTO archive(batchID, device, origin, window, bucket, descriptor, bytes) VALUES(?, ?, ?, ?, ?, ?, ?)",
                arguments: [try descriptor.batchID(), segment.deviceID, origin, segment.windowID, segment.bucket, encoded, snapshot.archiveBytes])
            let id = db.lastInsertedRowID
            for member in members { try db.execute(sql: "INSERT INTO archiveMember VALUES(?, ?)", arguments: [id, member["id"] as Int64]) }
        }
    }

    private func archiveRecord(_ row: Row) throws -> PushRawBatchRecord {
        let encoded: Data = row["descriptor"]
        let descriptor = try JSONDecoder().decode(ImuArchiveDescriptor.self, from: encoded)
        guard let bytes: Data = row["bytes"], PushDurabilityReceipt.sha256(bytes) == descriptor.fileSHA256 else { throw ImuPushSourceError.corruptSegment }
        return .init(rowId: row["id"], batchId: row["batchID"], capturedAt: descriptor.bucket,
            deviceClockRef: descriptor.bucket, wallClockRef: descriptor.bucket, startTs: descriptor.bucket,
            endTs: descriptor.bucket + ImuSessionFileStore.segmentSeconds, frameCount: 2,
            byteSize: Int32(encoded.count + bytes.count), framesBlob: try ImuArchiveDescriptor.framesBlob(descriptor: encoded, file: bytes))
    }

    func associateArchive(_ row: PushRawBatchRecord, receipt: PushDurabilityReceipt, scope: AccountScope) throws {
        isolation.lock(); defer { isolation.unlock() }
        guard self.scope == scope, receipt.isValid, receipt.ownerUserId == scope.userID, receipt.stream == "rawBatch" else { throw CloudUploadError.invalidReceipt }
        let (descriptor, bytes) = try ImuArchiveDescriptor.decode(row)
        guard descriptor.ownerNamespace == scope.namespace,
              receipt.contentSha256 == PushBinaryCodec.sha256Hex(try PushBinaryCodec.pack(table: .rawBatch, rows: [.rawBatch(row)])),
              receipt.deviceId == PushDurabilityReceipt.canonicalDevice(owner: scope.userID, device: descriptor.device) else { throw CloudUploadError.invalidReceipt }
        try index.write { db in
            guard let saved = try Row.fetchOne(db, sql: "SELECT * FROM archive WHERE batchID = ?", arguments: [row.batchId]),
                  (saved["bytes"] as Data?) == bytes, (saved["descriptor"] as Data) == (try descriptor.encoded()) else { throw CloudUploadError.invalidReceipt }
            try db.execute(sql: "UPDATE archive SET receipt = ? WHERE batchID = ?", arguments: [try JSONEncoder().encode(receipt), row.batchId])
        }
    }

    func checkArchiveCommit(_ commit: PushSourceCommit, scope: AccountScope) throws {
        isolation.lock(); defer { isolation.unlock() }
        guard self.scope == scope else { throw CloudUploadError.staleOwner }
        try verifyArchiveKeys(commit)
    }
    private func verifyArchiveKeys(_ commit: PushSourceCommit) throws {
        for key in commit.rawBatchIDs where ImuArchiveDescriptor.owns(key) {
            let encoded = try index.read { db in
                try Data.fetchOne(db, sql: "SELECT receipt FROM archive WHERE batchID = ? AND device = ? UNION ALL SELECT receipt FROM segmentCheckpoint WHERE batchID = ? AND device = ? LIMIT 1", arguments: [key, commit.deviceID, key, commit.deviceID])
            }
            guard let encoded, let receipt = try? JSONDecoder().decode(PushDurabilityReceipt.self, from: encoded),
                  receipt.isValid, receipt.ownerUserId == scope.userID, commit.batchIDs.contains(receipt.batchId) else { throw CloudUploadError.invalidReceipt }
        }
    }

    func sourceProgressApplied(_ commit: PushSourceCommit, scope: AccountScope) throws {
        isolation.lock(); defer { isolation.unlock() }
        guard self.scope == scope else { throw CloudUploadError.staleOwner }
        if commit.table == "rawImuSession", let cursor = commit.cursor {
            let existing = try index.read { try Int64.fetchOne($0, sql: "SELECT rowID FROM progressAnchor WHERE device = ?", arguments: [commit.deviceID]) } ?? 0
            if cursor.rowId > existing {
                guard let row = try index.read({ try Row.fetchOne($0, sql: "SELECT * FROM member WHERE device = ? AND id = ?", arguments: [commit.deviceID, cursor.rowId]) }),
                      let store = stores[row["origin"]] else { throw ImuPushSourceError.membershipUnavailable }
                let snap = try store.pushSegmentSnapshot(.init(windowID: row["window"], deviceID: commit.deviceID, bucket: row["bucket"]))
                guard let record = snap.records.first(where: { $0.ts == (row["ts"] as Int64) }),
                      PushDurabilityReceipt.sha256(record.columns) == (row["digest"] as String),
                      try PushProtocol.binaryKeyFingerprint(table: .rawImuSession, deviceId: commit.deviceID,
                        row: .rawImuSession(.init(rowId: cursor.rowId, ts: record.ts, columns: record.columns))) == cursor.naturalKeyFingerprint else { throw CloudUploadError.invalidReceipt }
                try index.write { db in
                    guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM rowReceipt WHERE memberID = ?)", arguments: [cursor.rowId]) == true else { throw CloudUploadError.invalidReceipt }
                    try db.execute(sql: "INSERT INTO progressAnchor VALUES(?, ?, ?, ?) ON CONFLICT(device) DO UPDATE SET rowID = excluded.rowID, ts = excluded.ts, columns = excluded.columns",
                        arguments: [commit.deviceID, cursor.rowId, record.ts, record.columns])
                }
            }
        } else if commit.table == "rawBatch" {
            try verifyArchiveKeys(commit)
            try index.write { db in
                for key in commit.rawBatchIDs where ImuArchiveDescriptor.owns(key) {
                    try db.execute(sql: "UPDATE archive SET committed = 1 WHERE batchID = ?", arguments: [key])
                }
            }
        }
        try maintainArchives()
    }

    func sourceCleanupCompleted(_ commit: PushSourceCommit, scope: AccountScope) throws {
        isolation.lock(); defer { isolation.unlock() }
        guard self.scope == scope else { throw CloudUploadError.staleOwner }
        try index.write { db in
            for key in commit.rawBatchIDs where ImuArchiveDescriptor.owns(key) {
                try db.execute(sql: "UPDATE archive SET cleaned = 1 WHERE batchID = ? AND committed = 1", arguments: [key])
            }
        }
        try maintainArchives()
    }

    /// At most one half-hour (1800 members) is compacted per call; queue cleanup and receipt
    /// sidecars remain retryable. One exact-prefix checkpoint replaces per-row receipt copies.
    private func maintainArchives() throws {
        if let archive = try index.read({ try Row.fetchOne($0, sql: """
            SELECT a.* FROM archive a WHERE a.committed = 1 AND a.compacted = 0
              AND NOT EXISTS(SELECT 1 FROM archiveMember am
                LEFT JOIN rowReceipt r ON r.memberID = am.memberID
                LEFT JOIN member m ON m.id = am.memberID
                LEFT JOIN progressAnchor p ON p.device = m.device
                WHERE am.archiveID = a.id AND (r.memberID IS NULL OR p.rowID IS NULL OR am.memberID > p.rowID))
            ORDER BY a.id LIMIT 1
            """) }) {
            let id: Int64 = archive["id"], encoded: Data = archive["receipt"]
            let receipt = try JSONDecoder().decode(PushDurabilityReceipt.self, from: encoded)
            let descriptor = try JSONDecoder().decode(ImuArchiveDescriptor.self, from: archive["descriptor"])
            guard receipt.isValid, receipt.ownerUserId == scope.userID, descriptor.ownerNamespace == scope.namespace else { throw CloudUploadError.invalidReceipt }
            try index.write { db in
                let members = try Int64.fetchAll(db, sql: "SELECT memberID FROM archiveMember WHERE archiveID = ?", arguments: [id])
                guard members.count == descriptor.members.count, Set(members) == Set(descriptor.members.map(\.rowID)) else { throw CloudUploadError.invalidReceipt }
                try db.execute(sql: """
                    INSERT INTO segmentCheckpoint(device, origin, window, bucket, batchID, bytes, records, digest, receipt)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(device, origin, window, bucket) DO UPDATE SET
                      batchID = excluded.batchID, bytes = excluded.bytes, records = excluded.records,
                      digest = excluded.digest, receipt = excluded.receipt, sidecarPending = 1
                    """, arguments: [descriptor.device, descriptor.origin, descriptor.window, descriptor.bucket,
                        archive["batchID"] as String, descriptor.fileBytes, descriptor.recordCount, descriptor.fileSHA256, encoded])
                try db.execute(sql: "DELETE FROM rowReceipt WHERE memberID IN (SELECT memberID FROM archiveMember WHERE archiveID = ?)", arguments: [id])
                try db.execute(sql: "DELETE FROM member WHERE id IN (SELECT memberID FROM archiveMember WHERE archiveID = ?)", arguments: [id])
                try db.execute(sql: "DELETE FROM archiveMember WHERE archiveID = ?", arguments: [id])
                try db.execute(sql: "UPDATE archive SET compacted = 1, bytes = NULL WHERE id = ?", arguments: [id])
            }
        }
        let pending = try index.read { try Row.fetchAll($0, sql: "SELECT * FROM segmentCheckpoint WHERE sidecarPending = 1 LIMIT 2") }
        for row in pending {
            let receipt = try JSONDecoder().decode(PushDurabilityReceipt.self, from: row["receipt"])
            guard receipt.isValid, let verified = PushDurabilityReceipt.date(receipt.verifiedAt), let store = stores[row["origin"]] else { throw CloudUploadError.invalidReceipt }
            let evidence = RawDurabilityReceipt(scope: .init(environment: scope.projectURL, accountID: scope.userID, deviceID: row["device"]),
                lane: "rawImuSession", resourceKey: "\(row["window"] as String)/\(row["bucket"] as Int64)",
                contentSHA256: row["digest"], objectKey: receipt.objectKey, receiptID: receipt.receiptId,
                verifiedAt: Int(verified.timeIntervalSince1970), retainUntil: Int(verified.timeIntervalSince1970))
            _ = try store.recordArchiveReceiptIfCurrent(evidence, id: row["window"], bucket: row["bucket"])
            try index.write { try $0.execute(sql: "UPDATE segmentCheckpoint SET sidecarPending = 0 WHERE batchID = ?", arguments: [row["batchID"] as String]) }
        }
        try index.write { try $0.execute(sql: "DELETE FROM archive WHERE id IN (SELECT id FROM archive WHERE compacted = 1 AND cleaned = 1 LIMIT 2)") }
        // Old indexes without auto-vacuum still reuse freed pages; never run a whole-file VACUUM
        // on an upload wake. New indexes return at most64 free pages per maintenance call.
        try index.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA incremental_vacuum(64)")
        }
    }

    private func reclaimMissingCheckpoints() throws {
        let last = try index.read { try Int64.fetchOne($0, sql: "SELECT afterRow FROM maintenanceCursor WHERE id = 1") } ?? 0
        let rows = try index.read { try Row.fetchAll($0, sql: "SELECT rowid AS checkpointID, * FROM segmentCheckpoint WHERE rowid > ? ORDER BY rowid LIMIT 8", arguments: [last]) }
        for row in rows {
            let occupied = try index.read { try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM archive WHERE batchID = ?)", arguments: [row["batchID"] as String]) } ?? true
            guard !occupied, (row["sidecarPending"] as Int) == 0,
                  let store = stores[row["origin"]], !store.hasSegment(id: row["window"], bucket: row["bucket"]),
                  try store.removeArchivedSidecarIfFileAbsent(id: row["window"], bucket: row["bucket"]) else { continue }
            try index.write { try $0.execute(sql: "DELETE FROM segmentCheckpoint WHERE rowid = ?", arguments: [row["checkpointID"] as Int64]) }
        }
        try index.write { try $0.execute(sql: "UPDATE maintenanceCursor SET afterRow = ? WHERE id = 1", arguments: [rows.last?["checkpointID"] as Int64? ?? 0]) }
    }
}
