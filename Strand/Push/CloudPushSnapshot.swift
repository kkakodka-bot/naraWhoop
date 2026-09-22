import Foundation
import CryptoKit
import Compression
import GRDB
import NoopPush
import WhoopStore

/// Read-only GRDB snapshot adapter for push batches. SQL identifiers come from closed NoopPush enums.
/// rawImuSession is file-backed (ImuSessionFileStore), not a GRDB table, so it is served by the
/// injected IMU source instead of SQL.
struct CloudPushSnapshot: PushSnapshotSource {
    private let db: any DatabaseWriter
    private let imuPushSource: (any ImuSessionPushSource)?
    private let allowsPreparation: @Sendable () -> Bool

    init(db: any DatabaseWriter, imuPushSource: (any ImuSessionPushSource)? = nil,
         allowsPreparation: @escaping @Sendable () -> Bool = { true }) {
        self.db = db
        self.imuPushSource = imuPushSource
        self.allowsPreparation = allowsPreparation
    }

    func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String] {
        guard allowsPreparation() else { throw PushSourceReadError.deferred }
        let tables = Set((capabilities.appendTables.map { sqlTable($0) }
            + capabilities.mutableTables.map { sqlTable($0) }
            + capabilities.binaryTables.filter { $0 != .rawImuSession }.map { binarySqlTable($0) })
            .compactMap(CloudSourceTable.init(rawValue:)))
        // Commit each bounded bootstrap page before reporting deferred work. Throwing inside
        // the write transaction would roll back its cursor and repeat the same source page.
        let membershipReady = try await db.read { try WhoopStore.cloudSourceMembership($0, tables: tables).isComplete }
        guard allowsPreparation() else { throw PushSourceReadError.deferred }
        if !membershipReady {
            let bootstrap = try await db.write { db in
                guard allowsPreparation() else { throw PushSourceReadError.deferred }
                return try WhoopStore.advanceCloudSourceBootstrap(db, tables: tables, maximumRows: 2_000)
            }
            guard bootstrap.isComplete, allowsPreparation() else { throw PushSourceReadError.deferred }
        }
        var ids = try await db.read { db in
            guard allowsPreparation() else { throw PushSourceReadError.deferred }
            let membership = try WhoopStore.cloudSourceMembership(db, tables: tables)
            guard membership.isComplete else { throw PushSourceReadError.deferred }
            var ids = Set(membership.deviceIDs)
            try String.fetchAll(db, sql: "SELECT id FROM device WHERE id <> ''").forEach { ids.insert($0) }
            // Revision tombstones preserve devices whose last mutable row was removed/rekeyed.
            for table in capabilities.mutableTables {
                try String.fetchAll(db, sql: "SELECT DISTINCT deviceId FROM cloudMutableRevision WHERE tableName = ? AND deviceId <> ''",
                    arguments: [table.wireName]).forEach { ids.insert($0) }
            }
            return ids
        }
        guard allowsPreparation() else { throw PushSourceReadError.deferred }
        if !capabilities.binaryTables.isDisjoint(with: [.rawImuSession, .rawBatch]), let imuPushSource {
            ids.formUnion(imuPushSource.pushDeviceIds())
            if let archives = imuPushSource as? any ImuExactArchiveSource {
                ids.formUnion(try archives.archiveDeviceIDs())
            }
        }
        guard allowsPreparation() else { throw PushSourceReadError.deferred }
        return Array(ids).sorted()
    }

    func mutableDirtyRanges(table: PushMutableTable, deviceId: String, afterRevision: Int64,
                            afterKey: String, limit: Int, calendar: Calendar) async throws -> PushMutableDirtyPage? {
        guard let sourceTable = CloudMutableTable(rawValue: table.wireName) else { throw PushSourceReadError.requiresCompatibleEncoding }
        guard allowsPreparation() else { throw PushSourceReadError.deferred }
        return try await db.read { db in
            guard allowsPreparation() else { throw PushSourceReadError.deferred }
            let page = try WhoopStore.cloudMutableDirtyRanges(db, table: sourceTable, deviceID: deviceId,
                afterRevision: afterRevision, afterKey: afterKey, limit: limit, calendar: calendar)
            return .init(ranges: page.ranges.map { .init(revision: $0.revision, key: $0.key, fromDay: $0.fromDay, toDay: $0.toDay) }, hasMore: page.hasMore)
        }
    }

    /// Cursor validation reads only natural-key columns, never retained payloads.
    func appendFingerprintAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> String? {
        try await db.read { db in
            let spec = appendSpec(table)
            guard let row = try Row.fetchOne(db, sql: "SELECT \(spec.keyColumns.joined(separator: ", ")) FROM \(spec.sqlName) WHERE deviceId = ? AND rowid = ?",
                arguments: [deviceId, rowId]) else { return nil }
            let key = Dictionary(uniqueKeysWithValues: spec.keyColumns.map { ($0, pushValue(row: row, column: $0, boolean: false)) })
            return try PushProtocol.keyFingerprint(table: table, deviceId: deviceId, key: key)
        }
    }

    func binaryFingerprintAt(table: PushBinaryTable, deviceId: String, rowId: Int64,
                             protocolVersion: String) async throws -> String? {
        if table == .rawImuSession {
            guard let value = try imuPushSource?.indexedPushRecord(deviceId: deviceId, rowId: rowId) else { return nil }
            return try PushProtocol.binaryKeyFingerprint(table: table, deviceId: deviceId,
                row: .rawImuSession(.init(rowId: value.rowId, ts: value.ts, columns: Data())))
        }
        return try await db.read { db in
            let columns: String
            switch table {
            case .ppgWaveformSample: columns = "ts, recordIndex, burstIndex"
            case .v18AuxSample: columns = "ts, recordIndex"
            case .rawBatch: return nil // raw batches have receipt membership instead of cursors
            case .rawImuSession: return nil
            }
            guard let row = try Row.fetchOne(db, sql: "SELECT \(columns) FROM \(binarySqlTable(table)) WHERE deviceId = ? AND rowid = ?",
                arguments: [deviceId, rowId]) else { return nil }
            let index: Int64? = (row["recordIndex"] as Int64?).flatMap { $0 >= 0 ? $0 : nil }
            let value: PushBinaryRow
            if table == .ppgWaveformSample {
                value = .ppgWaveform(.init(rowId: rowId, ts: row["ts"],
                    burstIndex: (row["burstIndex"] as Int64?).map { Int32(clamping: $0) }, samples: Data(), recordIndex: index))
            } else { value = .v18Aux(.init(rowId: rowId, ts: row["ts"], fields: Data(), recordIndex: index)) }
            return try PushProtocol.binaryKeyFingerprint(table: table, deviceId: deviceId, row: value,
                v18IdentityV2: protocolVersion == PushProtocol.auxiliaryIdentityVersion)
        }
    }

    /// A keyset/length pass and payload read share one SQLite snapshot. The first unsplittable
    /// member is never skipped; callers persist an explicit compatible-encoding pause.
    func appendPage(table: PushAppendTable, deviceId: String, afterRowId: Int64,
                    limit: Int, limits: PushSourceReadLimits) async throws -> PushAppendPage {
        guard limit > 0, limit <= PushProtocolLimits.maxRecords + 1 else { throw PushSourceReadError.requiresCompatibleEncoding }
        return try await db.read { db in
            guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
            let spec = appendSpec(table)
            let columns = spec.columns + (table.isScalarExtension ? ["provenanceJSON"] : [])
            let metadata = try Row.fetchAll(db, sql: "SELECT rowid AS id, \(lengthExpression(columns)) AS bytes FROM \(spec.sqlName) WHERE deviceId = ? AND rowid > ? ORDER BY rowid LIMIT ?",
                arguments: [deviceId, afterRowId, limit])
            var last: Int64?, count = 0, bytes = 0
            for row in metadata {
                guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
                let size: Int = row["bytes"]
                guard size >= 0, size <= limits.maximumDecodedBytes - bytes else {
                    if count == 0 { throw PushSourceReadError.requiresCompatibleEncoding }; break
                }
                bytes += size; count += 1; last = row["id"]
            }
            guard let last else { return .init(rows: [], hasMore: false) }
            let rows = try Row.fetchAll(db, sql: "SELECT rowid AS _pushRowId, \(columns.joined(separator: ", ")) FROM \(spec.sqlName) WHERE deviceId = ? AND rowid > ? AND rowid <= ? ORDER BY rowid LIMIT ?",
                arguments: [deviceId, afterRowId, last, count]).map { row in
                    guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
                    return try appendRecord(row: row, spec: spec, includeProvenance: table.isScalarExtension)
                }
            return .init(rows: rows, hasMore: count < metadata.count)
        }
    }

    private func lengthExpression(_ columns: [String]) -> String {
        // A small fixed allowance bounds numeric/key bookkeeping as well as variable text.
        "256 + " + columns.map { "COALESCE(length(CAST(\($0) AS BLOB)), 0)" }.joined(separator: " + ")
    }

    func binaryPage(table: PushBinaryTable, deviceId: String, afterRowId: Int64,
                    limit: Int, limits: PushSourceReadLimits) async throws -> PushBinaryPage {
        guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
        guard limit > 0, limit <= PushProtocolLimits.maxRecords + 1 else { throw PushSourceReadError.requiresCompatibleEncoding }
        if table == .rawImuSession {
            guard let imuPushSource else { throw ImuPushSourceError.membershipUnavailable }
            let count = max(1, min(limit, (max(0, limits.maximumDecodedBytes - 10) / 1220) + 1))
            let rows = try imuPushSource.indexedPushRows(deviceId: deviceId, afterRowId: afterRowId,
                limit: count, shouldContinue: limits.shouldContinue).map {
                    PushBinaryRow.rawImuSession(.init(rowId: $0.rowId, ts: $0.ts, columns: $0.columns))
                }
            return try boundedBinaryPage(rows, table: table, limits: limits, hasMore: count < limit && rows.count == count)
        }
        let page: PushBinaryPage = try await db.read { db in
            guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
            let name = binarySqlTable(table)
            let metadataColumns: String, payloadColumns: String, extra: String
            switch table {
            case .ppgWaveformSample:
                metadataColumns = "length(samples) AS bytes, recordIndex, burstIndex"
                payloadColumns = "ts, recordIndex, burstIndex, samples"; extra = ""
            case .v18AuxSample:
                metadataColumns = "length(fields) AS bytes, recordIndex, length(CAST(resourceKey AS BLOB)) AS keyBytes"
                payloadColumns = "ts, recordIndex, resourceKey, fields"; extra = ""
            case .rawBatch:
                metadataColumns = "length(framesBlob) AS bytes, length(CAST(batchId AS BLOB)) AS keyBytes"
                payloadColumns = "batchId, capturedAt, deviceClockRef, wallClockRef, startTs, endTs, frameCount, byteSize, framesBlob"
                extra = "AND syncedAt IS NULL"
            case .rawImuSession: return .init(rows: [], hasMore: false)
            }
            let metadata = try Row.fetchAll(db, sql: "SELECT rowid AS id, \(metadataColumns) FROM \(name) WHERE deviceId = ? AND rowid > ? \(extra) ORDER BY rowid LIMIT ?",
                arguments: [deviceId, afterRowId, limit])
            var used = PushBinaryCodec.packedHeaderSize(for: table), count = 0
            var last: Int64?
            for row in metadata {
                guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
                let payload: Int = row["bytes"]
                let overhead: Int
                switch table {
                case .ppgWaveformSample:
                    overhead = 21 + ((row["burstIndex"] as Int64?) == nil ? 0 : 4)
                        + (PushProtocol.hasPPGIdentity(limits.protocolVersion) ? ((row["recordIndex"] as Int64? ?? -1) < 0 ? 1 : 9) : 0)
                case .v18AuxSample:
                    guard (row["keyBytes"] as Int? ?? 0) <= 1024 else { throw PushSourceReadError.requiresCompatibleEncoding }
                    overhead = 20 + (limits.protocolVersion == PushProtocol.auxiliaryIdentityVersion ? ((row["recordIndex"] as Int64? ?? -1) < 0 ? 1 : 9) : 0)
                case .rawBatch:
                    let keyBytes: Int = row["keyBytes"]
                    guard keyBytes <= 65535 else { throw PushSourceReadError.requiresCompatibleEncoding }
                    overhead = 54 + keyBytes
                case .rawImuSession: overhead = 20
                }
                if payload < 0 || overhead > limits.maximumDecodedBytes - used || payload > limits.maximumDecodedBytes - used - overhead {
                    if count == 0 { throw PushSourceReadError.requiresCompatibleEncoding }; break
                }
                used += overhead + payload; count += 1; last = row["id"]
                if table == .rawBatch { break }
            }
            guard let last else { return .init(rows: [], hasMore: false) }
            let rows = try Row.fetchAll(db, sql: "SELECT rowid AS _pushRowId, \(payloadColumns) FROM \(name) WHERE deviceId = ? AND rowid > ? AND rowid <= ? \(extra) ORDER BY rowid LIMIT ?",
                arguments: [deviceId, afterRowId, last, count]).map { row -> PushBinaryRow in
                    guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
                    switch table {
                    case .ppgWaveformSample: return .ppgWaveform(ppgRecord(row: row))
                    case .v18AuxSample: return .v18Aux(try v18Record(row: row))
                    case .rawBatch: return .rawBatch(rawBatchRecord(row: row))
                    case .rawImuSession: throw ImuPushSourceError.membershipUnavailable
                    }
                }
            return .init(rows: rows, hasMore: count < metadata.count)
        }
        if table == .rawBatch, let archives = imuPushSource as? any ImuExactArchiveSource {
            if !page.rows.isEmpty { return .init(rows: page.rows, hasMore: true) }
            let rows = try archives.archiveRows(deviceID: deviceId, limit: 1, limits: limits).map(PushBinaryRow.rawBatch)
            // A further bounded query is required to prove the archive lane is empty.
            return try boundedBinaryPage(rows, table: table, limits: limits, hasMore: !rows.isEmpty)
        }
        return page
    }

    private func boundedBinaryPage(_ rows: [PushBinaryRow], table: PushBinaryTable,
                                   limits: PushSourceReadLimits, hasMore: Bool) throws -> PushBinaryPage {
        var count = 0, used = PushBinaryCodec.packedHeaderSize(for: table)
        for row in rows {
            guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
            let bytes = try PushBinaryCodec.packedRowSize(row, ppgIdentityV2: PushProtocol.hasPPGIdentity(limits.protocolVersion),
                v18IdentityV2: limits.protocolVersion == PushProtocol.auxiliaryIdentityVersion)
            if bytes > limits.maximumDecodedBytes - used {
                if count == 0 { throw PushSourceReadError.requiresCompatibleEncoding }; break
            }
            used += bytes; count += 1
            if table == .rawBatch { break }
        }
        return .init(rows: Array(rows.prefix(count)), hasMore: hasMore || count < rows.count)
    }

    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord? {
        try await db.read { db in
            let spec = appendSpec(table)
            let sql = """
                SELECT rowid AS _pushRowId, \(table.isScalarExtension ? "*" : spec.columns.joined(separator: ", "))
                FROM \(spec.sqlName)
                WHERE deviceId = ? AND rowid = ?
                LIMIT 1
                """
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [deviceId, rowId]) else { return nil }
            return try appendRecord(row: row, spec: spec, includeProvenance: table.isScalarExtension)
        }
    }

    func appendRows(
        table: PushAppendTable,
        deviceId: String,
        afterRowId: Int64,
        limit: Int
    ) async throws -> [PushAppendRecord] {
        precondition(limit >= 1 && limit <= PushProtocolLimits.maxRecords + 1)
        return try await db.read { db in
            let spec = appendSpec(table)
            let sql = """
                SELECT rowid AS _pushRowId, \(table.isScalarExtension ? "*" : spec.columns.joined(separator: ", "))
                FROM \(spec.sqlName)
                WHERE deviceId = ? AND rowid > ?
                ORDER BY rowid ASC
                LIMIT ?
                """
            return try Row.fetchAll(db, sql: sql, arguments: [deviceId, afterRowId, limit]).map {
                try appendRecord(row: $0, spec: spec, includeProvenance: table.isScalarExtension)
            }
        }
    }

    func mutableRows(
        table: PushMutableTable,
        deviceId: String,
        window: PushWindow,
        limit: Int
    ) async throws -> [PushMutableRecord] {
        precondition(limit >= 1 && limit <= PushProtocolLimits.maxMutableSnapshotRecords + 1)
        guard allowsPreparation() else { throw PushSourceReadError.deferred }
        return try await db.read { db in
            guard allowsPreparation() else { throw PushSourceReadError.deferred }
            let spec = mutableSpec(table)
            let (predicate, arguments): (String, [DatabaseValueConvertible?])
            switch table {
            case .dailyMetric, .journal:
                predicate = "deviceId = ? AND day >= ? AND day <= ?"
                arguments = [deviceId, window.fromDay, window.toDay]
            case .sleepSession, .workout:
                predicate = "deviceId = ? AND startTs >= ? AND startTs < ?"
                arguments = [deviceId, window.startTsInclusive, window.endTsExclusive]
            }
            // The cross-platform wire contract includes routes, but the Apple
            // workout schema does not require that optional column. Keep a
            // stored route when present; otherwise publish its explicit null.
            // All other required columns remain strict schema requirements.
            var selectColumns = spec.columns
            if table == .workout,
               try !db.columns(in: spec.sqlName).contains(where: { $0.name == "routePolyline" }) {
                selectColumns = spec.columns.map {
                    $0 == "routePolyline" ? "NULL AS routePolyline" : $0
                }
            }
            let sql = """
                SELECT \(selectColumns.joined(separator: ", "))
                FROM \(spec.sqlName)
                WHERE \(predicate)
                ORDER BY \(spec.keyColumns.joined(separator: ", ")) ASC
                LIMIT ?
                """
            let sizes = try Int.fetchAll(db, sql: "SELECT \(lengthExpression(spec.columns)) FROM \(spec.sqlName) WHERE \(predicate) ORDER BY \(spec.keyColumns.joined(separator: ", ")) ASC LIMIT ?",
                arguments: StatementArguments(arguments + [limit]))
            var remaining = PushProtocolLimits.maxMutableSnapshotEncodedBytes
            for size in sizes {
                guard allowsPreparation() else { throw PushSourceReadError.deferred }
                guard size >= 0, size <= remaining else { throw PushSourceReadError.requiresCompatibleEncoding }
                remaining -= size
            }
            // Replacement windows are all-or-nothing: never return a byte-truncated subset.
            guard sizes.count <= PushProtocolLimits.maxMutableSnapshotRecords else { throw PushSourceReadError.requiresCompatibleEncoding }
            guard allowsPreparation() else { throw PushSourceReadError.deferred }
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments + [limit])).map {
                guard allowsPreparation() else { throw PushSourceReadError.deferred }
                return mutableRecord(row: $0, spec: spec)
            }
        }
    }

    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) async throws -> PushBinaryRow? {
        if table == .rawImuSession {
            guard let imuPushSource,
                  let record = try imuPushSource.indexedPushRecord(deviceId: deviceId, rowId: rowId) else { return nil }
            return .rawImuSession(PushRawImuRecord(rowId: record.rowId, ts: record.ts, columns: record.columns))
        }
        return try await db.read { db in
            switch table {
            case .ppgWaveformSample:
                let sql = """
                    SELECT rowid AS _pushRowId, ts, recordIndex, burstIndex, samples
                    FROM ppgWaveformSample
                    WHERE deviceId = ? AND rowid = ?
                    LIMIT 1
                    """
                guard let row = try Row.fetchOne(db, sql: sql, arguments: [deviceId, rowId]) else { return nil }
                return .ppgWaveform(ppgRecord(row: row))
            case .v18AuxSample:
                let sql = """
                    SELECT rowid AS _pushRowId, *
                    FROM v18AuxSample
                    WHERE deviceId = ? AND rowid = ?
                    LIMIT 1
                    """
                guard let row = try Row.fetchOne(db, sql: sql, arguments: [deviceId, rowId]) else { return nil }
                return .v18Aux(try v18Record(row: row))
            case .rawBatch:
                let sql = """
                    SELECT rowid AS _pushRowId, batchId, capturedAt, deviceClockRef, wallClockRef,
                           startTs, endTs, frameCount, byteSize, framesBlob
                    FROM rawBatch
                    WHERE deviceId = ? AND rowid = ? AND syncedAt IS NULL
                    LIMIT 1
                    """
                guard let row = try Row.fetchOne(db, sql: sql, arguments: [deviceId, rowId]) else { return nil }
                return .rawBatch(rawBatchRecord(row: row))
            case .rawImuSession:
                return nil // unreachable: handled above before the GRDB read
            }
        }
    }

    func binaryRows(
        table: PushBinaryTable,
        deviceId: String,
        afterRowId: Int64,
        limit: Int
    ) async throws -> [PushBinaryRow] {
        let interval = SyncPipelineTrace.begin(.uploadPreparation)
        var outcome: SyncPipelineTrace.Outcome = .failed
        defer { SyncPipelineTrace.end(interval, outcome: outcome) }
        precondition(limit >= 1)
        if table == .rawImuSession {
            guard let imuPushSource else { throw ImuPushSourceError.membershipUnavailable }
            let records: [PushBinaryRow] = try imuPushSource.indexedPushRows(deviceId: deviceId, afterRowId: afterRowId, limit: limit)
                .map { .rawImuSession(PushRawImuRecord(rowId: $0.rowId, ts: $0.ts, columns: $0.columns)) }
            outcome = .succeeded
            return records
        }
        var records: [PushBinaryRow] = try await db.read { db in
            switch table {
            case .ppgWaveformSample:
                let sql = """
                    SELECT rowid AS _pushRowId, ts, recordIndex, burstIndex, samples
                    FROM ppgWaveformSample
                    WHERE deviceId = ? AND rowid > ?
                    ORDER BY rowid ASC
                    LIMIT ?
                    """
                return try Row.fetchAll(db, sql: sql, arguments: [deviceId, afterRowId, limit]).map {
                    PushBinaryRow.ppgWaveform(ppgRecord(row: $0))
                }
            case .v18AuxSample:
                let sql = """
                    SELECT rowid AS _pushRowId, *
                    FROM v18AuxSample
                    WHERE deviceId = ? AND rowid > ?
                    ORDER BY rowid ASC
                    LIMIT ?
                    """
                return try Row.fetchAll(db, sql: sql, arguments: [deviceId, afterRowId, limit]).map {
                    PushBinaryRow.v18Aux(try v18Record(row: $0))
                }
            case .rawBatch:
                let sql = """
                    SELECT rowid AS _pushRowId, batchId, capturedAt, deviceClockRef, wallClockRef,
                           startTs, endTs, frameCount, byteSize, framesBlob
                    FROM rawBatch
                    WHERE deviceId = ? AND syncedAt IS NULL AND rowid > ?
                    ORDER BY rowid ASC
                    LIMIT ?
                    """
                return try Row.fetchAll(db, sql: sql, arguments: [deviceId, afterRowId, limit]).map {
                    PushBinaryRow.rawBatch(rawBatchRecord(row: $0))
                }
            case .rawImuSession:
                return [] // unreachable: handled above before the GRDB read
            }
        }
        if table == .rawBatch, records.count < limit, let archives = imuPushSource as? any ImuExactArchiveSource {
            records += try archives.archiveRows(deviceID: deviceId, limit: min(2, limit - records.count)).map(PushBinaryRow.rawBatch)
        }
        outcome = .succeeded
        return records
    }

    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) async throws {
        guard table == .rawBatch else { return }
        let batchIds = rows.compactMap { row -> String? in
            guard case .rawBatch(let record) = row else { return nil }
            return record.batchId
        }
        guard !batchIds.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        try await db.write { db in
            for batchId in batchIds {
                try db.execute(
                    sql: "UPDATE rawBatch SET syncedAt = ? WHERE deviceId = ? AND batchId = ?",
                    arguments: [now, deviceId, batchId]
                )
            }
        }
    }

    /// One transaction binds exactly the uploaded prefix to capture-time identities. A legacy or
    /// unassigned resource is retained. No natural-key reconstruction can adopt another owner's row.
    func associateReceipt(batch: PushBinaryBatch, rows: [PushBinaryRow], receipt: PushDurabilityReceipt,
                          scope: AccountScope) async throws {
        // Object-ID conflict recovery can change the remote object ID, never its payload identity.
        let manifest = PushObjectManifest(batch: batch).replacingObjectId(receipt.objectId)
        guard receipt.matches(manifest, owner: scope,
                wireSHA256: batch.wireSHA256, wireBytes: batch.wireBytes),
              let verified = PushDurabilityReceipt.date(receipt.verifiedAt) else { throw CloudUploadError.invalidReceipt }
        // Bind the supplied membership to the attested bytes at the source mutation boundary too.
        // This is bounded packing, not recompression; no unauthenticated row list can release siblings.
        var index = 0, digest = SHA256()
        let size = try PushBinaryStreamEncoder.visitDecodedBytes(table: batch.table, rowCount: rows.count,
            ppgIdentityV2: PushProtocol.hasPPGIdentity(batch.protocolVersion),
            v18IdentityV2: batch.protocolVersion == PushProtocol.auxiliaryIdentityVersion,
            maxDecodedBytes: PushProtocolLimits.maxObjectDecodedBytes, maxRows: PushProtocolLimits.maxRecords,
            nextRow: { guard index < rows.count else { return nil }; defer { index += 1 }; return rows[index] },
            consume: { digest.update(bufferPointer: $0) })
        guard size == batch.uncompressedBytes,
              digest.finalize().map({ String(format: "%02x", $0) }).joined() == receipt.contentSha256 else { throw CloudUploadError.invalidReceipt }
        let capture = DurableIngestScope(environment: scope.projectURL, accountID: scope.userID, deviceID: batch.deviceId)
        if batch.table == .rawImuSession {
            guard let imuPushSource else { throw ImuPushSourceError.membershipUnavailable }
            let imuRows = rows.compactMap { row -> PushRawImuRecord? in
                if case .rawImuSession(let record) = row { return record }; return nil
            }
            guard imuRows.count == rows.count else { throw CloudUploadError.invalidReceipt }
            try imuPushSource.associatePushReceipt(rows: imuRows, receipt: receipt, scope: scope)
            return
        }
        var resources: [(String, String)] = []
        for row in rows {
            switch row {
            case .ppgWaveform(let r):
                var bytes = Data("\(r.burstIndex.map(String.init) ?? "unknown")\n".utf8)
                bytes.append(r.samples)
                resources.append(("\(r.ts):\(r.recordIndex ?? -1)", PushDurabilityReceipt.sha256(bytes)))
            case .v18Aux(let r): resources.append((r.resourceKey ?? String(r.ts), PushDurabilityReceipt.sha256(r.fields)))
            case .rawBatch(let r):
                if ImuArchiveDescriptor.owns(r.batchId) {
                    guard let archives = imuPushSource as? any ImuExactArchiveSource else { throw CloudUploadError.invalidReceipt }
                    try archives.associateArchive(r, receipt: receipt, scope: scope)
                } else { resources.append((r.batchId, PushDurabilityReceipt.sha256(try Self.rawResourceBytes(r.framesBlob)))) }
            case .rawImuSession:
                // Whole-segment pruning requires an explicit complete membership proof, not a
                // receipt for an arbitrary row prefix. Retain until the file-source API supplies it.
                throw CloudUploadError.invalidReceipt
            }
        }
        let capturedResources = resources
        let capturedAuxiliary = rows.compactMap { row -> PushV18AuxRecord? in
            if case .v18Aux(let value) = row { return value }; return nil
        }
        guard !capturedResources.isEmpty else { return }
        try await db.write { db in
            guard let owner = try Row.fetchOne(db, sql: "SELECT projectURL, userID FROM localAccountOwner WHERE singleton = 1"),
                  (owner["projectURL"] as String) == scope.projectURL,
                  (owner["userID"] as String) == scope.userID else { throw CloudUploadError.staleOwner }
            for auxiliary in capturedAuxiliary {
                guard let stored = try String.fetchOne(db, sql: """
                    SELECT resourceKey FROM v18AuxSample
                    WHERE rowid=? AND deviceId=? AND ts=? AND recordIndex=? AND fields=?
                    """, arguments: [auxiliary.rowId, batch.deviceId, auxiliary.ts,
                        auxiliary.recordIndex ?? -1, auxiliary.fields]),
                      stored == (auxiliary.resourceKey ?? String(auxiliary.ts)) else { throw CloudUploadError.invalidReceipt }
            }
            for (key, digest) in capturedResources {
                guard let resource = try Row.fetchOne(db, sql: """
                    SELECT scopeKey, contentSHA256 FROM ingestRawResource
                    WHERE lane = ? AND deviceId = ? AND resourceKey = ?
                    """, arguments: [batch.wireName, batch.deviceId, key]),
                      (resource["scopeKey"] as String) == capture.key,
                      (resource["contentSHA256"] as String) == digest else { throw CloudUploadError.invalidReceipt }
                try db.execute(sql: """
                    INSERT INTO rawDurabilityReceipt
                        (lane, deviceId, resourceKey, scopeKey, contentSHA256, objectKey, receiptId, verifiedAt, retainUntil)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(lane, deviceId, resourceKey, scopeKey, contentSHA256) DO NOTHING
                    """, arguments: [batch.wireName, batch.deviceId, key, capture.key, digest,
                                      receipt.objectKey, receipt.receiptId, Int(verified.timeIntervalSince1970),
                                      Int(verified.timeIntervalSince1970)])
            }
        }
    }

    private static func rawResourceBytes(_ blob: Data) throws -> Data {
        guard blob.count >= 4 else { throw CloudUploadError.invalidReceipt }
        let bytes = [UInt8](blob.prefix(4))
        let size = bytes.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        guard size > 0, size <= PushProtocolLimits.maxObjectDecodedBytes else { throw CloudUploadError.invalidReceipt }
        var decoded = Data(count: size)
        let written = decoded.withUnsafeMutableBytes { output in
            blob.dropFirst(4).withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, size,
                    input.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw CloudUploadError.invalidReceipt }
        return decoded
    }

    /// Replay only an intent staged after full receipt association; raw rows without that proof
    /// still fail closed here. Other lanes have no source-side mutable ACK.
    func acknowledgeCommitted(_ commit: PushSourceCommit, scope: AccountScope) async throws {
        guard commit.kind == .binary, commit.table == PushBinaryTable.rawBatch.wireName else { return }
        let archiveKeys = commit.rawBatchIDs.filter(ImuArchiveDescriptor.owns)
        if !archiveKeys.isEmpty {
            guard let archives = imuPushSource as? any ImuExactArchiveSource else { throw CloudUploadError.invalidReceipt }
            try archives.checkArchiveCommit(commit, scope: scope)
        }
        let capture = DurableIngestScope(environment: scope.projectURL, accountID: scope.userID, deviceID: commit.deviceID)
        try await db.write { db in
            for key in commit.rawBatchIDs where !ImuArchiveDescriptor.owns(key) {
                guard try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM ingestRawResource r JOIN rawDurabilityReceipt a
                      ON a.scopeKey = r.scopeKey AND a.lane = r.lane AND a.deviceId = r.deviceId
                        AND a.resourceKey = r.resourceKey AND a.contentSHA256 = r.contentSHA256
                      WHERE r.scopeKey = ? AND r.lane = 'rawBatch' AND r.deviceId = ? AND r.resourceKey = ?)
                    """, arguments: [capture.key, commit.deviceID, key]) == true else { throw CloudUploadError.invalidReceipt }
                try db.execute(sql: "UPDATE rawBatch SET syncedAt = COALESCE(syncedAt, ?) WHERE deviceId = ? AND batchId = ?",
                               arguments: [Int(Date().timeIntervalSince1970), commit.deviceID, key])
            }
        }
    }

    func sourceProgressApplied(_ commit: PushSourceCommit, scope: AccountScope) throws {
        try (imuPushSource as? any ImuExactArchiveSource)?.sourceProgressApplied(commit, scope: scope)
    }
    func sourceCleanupCompleted(_ commit: PushSourceCommit, scope: AccountScope) throws {
        try (imuPushSource as? any ImuExactArchiveSource)?.sourceCleanupCompleted(commit, scope: scope)
    }

    private func binarySqlTable(_ table: PushBinaryTable) -> String {
        switch table {
        case .ppgWaveformSample: return "ppgWaveformSample"
        case .v18AuxSample: return "v18AuxSample"
        case .rawBatch: return "rawBatch"
        case .rawImuSession: return "rawImuSession" // file-backed; never queried — see knownDeviceIds
        }
    }

    private func ppgRecord(row: Row) -> PushPpgWaveformRecord {
        let burstIndex = row["burstIndex"] as Int64?
        return PushPpgWaveformRecord(
            rowId: row["_pushRowId"],
            ts: row["ts"],
            burstIndex: burstIndex.map { Int32(clamping: $0) },
            samples: row["samples"],
            recordIndex: (row["recordIndex"] as Int64?).flatMap { $0 >= 0 ? $0 : nil }
        )
    }

    private func v18Record(row: Row) throws -> PushV18AuxRecord {
        let fields: Data = row["fields"]
        let index = V18AuxCodec.strictRecordIndex(in: fields).map(Int64.init)
        if row.columnNames.contains("recordIndex") {
            let saved: Int64 = row["recordIndex"]
            guard saved == (index ?? -1) else { throw PushProtocolException("auxiliary stored identity mismatch") }
        }
        let resource: String = row.columnNames.contains("resourceKey") ? row["resourceKey"] : String(row["ts"] as Int64)
        guard !resource.isEmpty else { throw PushProtocolException("missing auxiliary receipt identity") }
        return PushV18AuxRecord(rowId: row["_pushRowId"], ts: row["ts"], fields: fields,
                                recordIndex: index, resourceKey: resource)
    }

    private func rawBatchRecord(row: Row) -> PushRawBatchRecord {
        PushRawBatchRecord(
            rowId: row["_pushRowId"],
            batchId: row["batchId"],
            capturedAt: row["capturedAt"],
            deviceClockRef: row["deviceClockRef"],
            wallClockRef: row["wallClockRef"],
            startTs: row["startTs"],
            endTs: row["endTs"],
            frameCount: Int32(clamping: row["frameCount"] as Int64),
            byteSize: Int32(clamping: row["byteSize"] as Int64),
            framesBlob: row["framesBlob"]
        )
    }

    private func mutableSpec(_ table: PushMutableTable) -> TableSpec {
        switch table {
        case .dailyMetric:
            return TableSpec(
                sqlName: "dailyMetric",
                keyColumns: ["day"],
                dataColumns: [
                    "totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances",
                    "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct",
                    "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir",
                ],
                booleanColumns: []
            )
        case .sleepSession:
            return TableSpec(
                sqlName: "sleepSession",
                keyColumns: ["startTs"],
                dataColumns: [
                    "endTs", "efficiency", "restingHr", "avgHrv", "stagesJSON", "userEdited",
                    "startTsAdjusted", "motionJSON", "sleepStateJSON", "stagingSparse",
                ],
                booleanColumns: ["userEdited", "stagingSparse"]
            )
        case .workout:
            return TableSpec(
                sqlName: "workout",
                keyColumns: ["startTs", "sport"],
                dataColumns: [
                    "endTs", "source", "durationS", "energyKcal", "avgHr", "maxHr", "strain",
                    "distanceM", "zonesJSON", "notes", "routePolyline", "steps",
                ],
                booleanColumns: []
            )
        case .journal:
            return TableSpec(
                sqlName: "journal",
                keyColumns: ["day", "question"],
                dataColumns: ["answeredYes", "notes", "numericValue"],
                booleanColumns: ["answeredYes"]
            )
        }
    }

    private func mutableRecord(row: Row, spec: TableSpec) -> PushMutableRecord {
        let key = Dictionary(uniqueKeysWithValues: spec.keyColumns.map {
            ($0, pushValue(row: row, column: $0, boolean: spec.booleanColumns.contains($0)))
        })
        let data = Dictionary(uniqueKeysWithValues: spec.dataColumns.map {
            ($0, pushValue(row: row, column: $0, boolean: spec.booleanColumns.contains($0)))
        })
        return PushMutableRecord(key: key, data: data)
    }

    private struct TableSpec {
        let sqlName: String
        let keyColumns: [String]
        let dataColumns: [String]
        let booleanColumns: Set<String>
        var columns: [String] { keyColumns + dataColumns }
    }

    private func appendSpec(_ table: PushAppendTable) -> TableSpec {
        switch table {
        case .hrSample: return TableSpec(sqlName: "hrSample", keyColumns: ["ts"], dataColumns: ["bpm"], booleanColumns: [])
        case .rrInterval: return TableSpec(sqlName: "rrInterval", keyColumns: ["ts", "rrMs", "seq"], dataColumns: ["ord", "srcChannel", "tsSuspect"], booleanColumns: ["tsSuspect"])
        case .rrPacketProvenance: return TableSpec(
            sqlName: "rrPacketProvenance", keyColumns: ["packetId"],
            dataColumns: ["ts", "sensorTs", "recordIndex", "rawHex", "srcChannel", "schemaVersion", "decoderVersion", "clockVersion", "timestampPrecisionSeconds", "clockOffsetSeconds", "declaredCount"],
            booleanColumns: [])
        case .standardHRReceipt: return TableSpec(
            sqlName: "standardHRReceipt", keyColumns: ["receiptId"],
            dataColumns: ["ts", "sessionId", "notificationOrdinal", "receivedUnixMs", "receivedMonotonicNs", "rawHex", "schemaVersion", "clockVersion"],
            booleanColumns: [])
        case .event: return TableSpec(sqlName: "event", keyColumns: ["ts", "kind"], dataColumns: ["payloadJSON"], booleanColumns: [])
        case .battery: return TableSpec(sqlName: "battery", keyColumns: ["ts"], dataColumns: ["soc", "mv", "charging"], booleanColumns: ["charging"])
        case .spo2Sample: return TableSpec(sqlName: "spo2Sample", keyColumns: ["ts"], dataColumns: ["red", "ir"], booleanColumns: [])
        case .skinTempSample: return TableSpec(sqlName: "skinTempSample", keyColumns: ["ts"], dataColumns: ["raw", "aux1Raw", "aux2Raw"], booleanColumns: [])
        case .respSample: return TableSpec(sqlName: "respSample", keyColumns: ["ts"], dataColumns: ["raw"], booleanColumns: [])
        case .gravitySample: return TableSpec(sqlName: "gravitySample", keyColumns: ["ts"], dataColumns: ["x", "y", "z", "dynAccel"], booleanColumns: [])
        case .stepSample: return TableSpec(sqlName: "stepSample", keyColumns: ["ts"], dataColumns: ["counter", "activityClass"], booleanColumns: [])
        case .sleepStateSample: return TableSpec(sqlName: "sleepStateSample", keyColumns: ["ts"], dataColumns: ["state", "rawByte"], booleanColumns: [])
        case .ppgHrSample: return TableSpec(sqlName: "ppgHrSample", keyColumns: ["ts"], dataColumns: ["bpm", "conf"], booleanColumns: [])
        }
    }

    private func sqlTable(_ table: PushAppendTable) -> String { appendSpec(table).sqlName }
    private func sqlTable(_ table: PushMutableTable) -> String {
        switch table {
        case .dailyMetric: return "dailyMetric"
        case .sleepSession: return "sleepSession"
        case .workout: return "workout"
        case .journal: return "journal"
        }
    }

    private func appendRecord(row: Row, spec: TableSpec, includeProvenance: Bool) throws -> PushAppendRecord {
        let rowId = row["_pushRowId"] as Int64
        let key = Dictionary(uniqueKeysWithValues: spec.keyColumns.map {
            ($0, pushValue(row: row, column: $0, boolean: spec.booleanColumns.contains($0)))
        })
        var data = Dictionary(uniqueKeysWithValues: spec.dataColumns.map {
            ($0, pushValue(row: row, column: $0, boolean: spec.booleanColumns.contains($0)))
        })
        if includeProvenance, row.columnNames.contains("provenanceJSON"),
           let provenance: String = row["provenanceJSON"] {
            data["provenance"] = try PushProtocol.scalarProvenanceJSON(Data(provenance.utf8))
        }
        return PushAppendRecord(rowId: rowId, key: key, data: data)
    }

    private func pushValue(row: Row, column: String, boolean: Bool) -> PushJSONValue {
        let dbValue: DatabaseValue = row[column]
        if dbValue.isNull { return .null }
        if boolean, let v = Int64.fromDatabaseValue(dbValue) { return .bool(v != 0) }
        // Nanosecond clocks can exceed JavaScript's exact integer range. The
        // receipt wire contract uses decimal strings on both mobile platforms,
        // even for small clocks, so Edge never rounds a timing observation.
        if column == "receivedMonotonicNs", let v = Int64.fromDatabaseValue(dbValue) {
            return .string(String(v))
        }
        if let v = Int64.fromDatabaseValue(dbValue) { return .int(v) }
        if let v = Double.fromDatabaseValue(dbValue) { return .double(v) }
        if let v = String.fromDatabaseValue(dbValue) { return .string(v) }
        if let v = Bool.fromDatabaseValue(dbValue) { return .bool(v) }
        return .null
    }
}
