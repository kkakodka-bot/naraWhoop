import Foundation
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

    init(db: any DatabaseWriter, imuPushSource: (any ImuSessionPushSource)? = nil) {
        self.db = db
        self.imuPushSource = imuPushSource
    }

    func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String] {
        var ids = try await db.read { db in
            var ids = Set<String>()
            let deviceRows = try String.fetchAll(db, sql: "SELECT id FROM device WHERE id <> ''")
            deviceRows.forEach { ids.insert($0) }
            for table in capabilities.appendTables {
                let sql = "SELECT DISTINCT deviceId FROM \(sqlTable(table)) WHERE deviceId <> ''"
                try String.fetchAll(db, sql: sql).forEach { ids.insert($0) }
            }
            for table in capabilities.mutableTables {
                let sql = "SELECT DISTINCT deviceId FROM \(sqlTable(table)) WHERE deviceId <> ''"
                try String.fetchAll(db, sql: sql).forEach { ids.insert($0) }
            }
            for table in capabilities.binaryTables where table != .rawImuSession {
                let sql = "SELECT DISTINCT deviceId FROM \(binarySqlTable(table)) WHERE deviceId <> ''"
                try String.fetchAll(db, sql: sql).forEach { ids.insert($0) }
            }
            return ids
        }
        if !capabilities.binaryTables.isDisjoint(with: [.rawImuSession, .rawBatch]), let imuPushSource {
            ids.formUnion(imuPushSource.pushDeviceIds())
            if let archives = imuPushSource as? any ImuExactArchiveSource {
                ids.formUnion(try archives.archiveDeviceIDs())
            }
        }
        return Array(ids).sorted()
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
        return try await db.read { db in
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
            let sql = """
                SELECT \(spec.columns.joined(separator: ", "))
                FROM \(spec.sqlName)
                WHERE \(predicate)
                ORDER BY \(spec.keyColumns.joined(separator: ", ")) ASC
                LIMIT ?
                """
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments + [limit])).map {
                mutableRecord(row: $0, spec: spec)
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
                wireSHA256: PushDurabilityReceipt.sha256(batch.payload), wireBytes: batch.payload.count),
              let verified = PushDurabilityReceipt.date(receipt.verifiedAt) else { throw CloudUploadError.invalidReceipt }
        // Bind the supplied membership to the attested bytes at the source mutation boundary too.
        // This is bounded packing, not recompression; no unauthenticated row list can release siblings.
        let packed = try PushBinaryCodec.pack(table: batch.table, rows: rows,
            ppgIdentityV2: PushProtocol.hasPPGIdentity(batch.protocolVersion),
            v18IdentityV2: batch.protocolVersion == PushProtocol.auxiliaryIdentityVersion)
        guard packed.count == batch.uncompressedBytes,
              PushDurabilityReceipt.sha256(packed) == receipt.contentSha256 else { throw CloudUploadError.invalidReceipt }
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
        if let v = Int64.fromDatabaseValue(dbValue) { return .int(v) }
        if let v = Double.fromDatabaseValue(dbValue) { return .double(v) }
        if let v = String.fromDatabaseValue(dbValue) { return .string(v) }
        if let v = Bool.fromDatabaseValue(dbValue) { return .bool(v) }
        return .null
    }
}
