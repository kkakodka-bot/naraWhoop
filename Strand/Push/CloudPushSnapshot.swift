import Foundation
import Compression
import GRDB
import NoopPush

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
        if capabilities.binaryTables.contains(.rawImuSession), let imuPushSource {
            ids.formUnion(await imuPushSource.pushDeviceIds())
        }
        return Array(ids).sorted()
    }

    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord? {
        try await db.read { db in
            let spec = appendSpec(table)
            let sql = """
                SELECT rowid AS _pushRowId, \(spec.columns.joined(separator: ", "))
                FROM \(spec.sqlName)
                WHERE deviceId = ? AND rowid = ?
                LIMIT 1
                """
            guard let row = try Row.fetchOne(db, sql: sql, arguments: [deviceId, rowId]) else { return nil }
            return appendRecord(row: row, spec: spec)
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
                SELECT rowid AS _pushRowId, \(spec.columns.joined(separator: ", "))
                FROM \(spec.sqlName)
                WHERE deviceId = ? AND rowid > ?
                ORDER BY rowid ASC
                LIMIT ?
                """
            return try Row.fetchAll(db, sql: sql, arguments: [deviceId, afterRowId, limit]).map {
                appendRecord(row: $0, spec: spec)
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
                SELECT \(try spec.selectColumns(in: db).joined(separator: ", "))
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
            // The IMU cursor is the record's ts, so "record at cursor" is the record with that ts.
            guard let imuPushSource,
                  let record = await imuPushSource.pushRecords(deviceId: deviceId, afterTs: rowId - 1, limit: 1).first,
                  record.ts == rowId else { return nil }
            return .rawImuSession(PushRawImuRecord(rowId: record.ts, ts: record.ts, columns: record.columns))
        }
        return try await db.read { db in
            switch table {
            case .ppgWaveformSample:
                let sql = """
                    SELECT rowid AS _pushRowId, ts, burstIndex, samples, recordIndex
                    FROM ppgWaveformSample
                    WHERE deviceId = ? AND rowid = ?
                    LIMIT 1
                    """
                guard let row = try Row.fetchOne(db, sql: sql, arguments: [deviceId, rowId]) else { return nil }
                return .ppgWaveform(ppgRecord(row: row))
            case .v18AuxSample:
                let sql = """
                    SELECT rowid AS _pushRowId, ts, fields
                    FROM v18AuxSample
                    WHERE deviceId = ? AND rowid = ?
                    LIMIT 1
                    """
                guard let row = try Row.fetchOne(db, sql: sql, arguments: [deviceId, rowId]) else { return nil }
                return .v18Aux(v18Record(row: row))
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
        precondition(limit >= 1)
        if table == .rawImuSession {
            guard let imuPushSource else { return [] }
            return await imuPushSource.pushRecords(deviceId: deviceId, afterTs: afterRowId, limit: limit)
                .map { .rawImuSession(PushRawImuRecord(rowId: $0.ts, ts: $0.ts, columns: $0.columns)) }
        }
        return try await db.read { db in
            switch table {
            case .ppgWaveformSample:
                let sql = """
                    SELECT rowid AS _pushRowId, ts, burstIndex, samples, recordIndex
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
                    SELECT rowid AS _pushRowId, ts, fields
                    FROM v18AuxSample
                    WHERE deviceId = ? AND rowid > ?
                    ORDER BY rowid ASC
                    LIMIT ?
                    """
                return try Row.fetchAll(db, sql: sql, arguments: [deviceId, afterRowId, limit]).map {
                    PushBinaryRow.v18Aux(v18Record(row: $0))
                }
            case .rawBatch:
                let sql = """
                    SELECT rowid AS _pushRowId, batchId, capturedAt, deviceClockRef, wallClockRef,
                           startTs, endTs, frameCount, byteSize, framesBlob
                    FROM rawBatch
                    WHERE deviceId = ? AND syncedAt IS NULL AND rowid > ?
                    ORDER BY capturedAt ASC, rowid ASC
                    LIMIT ?
                    """
                return try Row.fetchAll(db, sql: sql, arguments: [deviceId, afterRowId, limit]).map {
                    PushBinaryRow.rawBatch(rawBatchRecord(row: $0))
                }
            case .rawImuSession:
                return [] // unreachable: handled above before the GRDB read
            }
        }
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
            recordIndex: (row["recordIndex"] as Int64?).flatMap { $0 < 0 ? nil : $0 }
        )
    }

    private func v18Record(row: Row) -> PushV18AuxRecord {
        PushV18AuxRecord(rowId: row["_pushRowId"], ts: row["ts"], fields: row["fields"])
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
                booleanColumns: [],
                optionalLocalColumns: ["routePolyline"]
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
        var optionalLocalColumns: Set<String> = []
        var columns: [String] { keyColumns + dataColumns }

        func selectColumns(in db: Database) throws -> [String] {
            guard !optionalLocalColumns.isEmpty else { return columns }
            let available = Set(try db.columns(in: sqlName).map(\.name))
            // routePolyline is part of the shared wire contract but only Android currently
            // stores it. Export an explicit null on Apple; preserve it if a future migration
            // adds the field. Missing required columns must still fail instead of hiding damage.
            return columns.map { optionalLocalColumns.contains($0) && !available.contains($0) ? "NULL AS \($0)" : $0 }
        }
    }

    private func appendSpec(_ table: PushAppendTable) -> TableSpec {
        switch table {
        case .hrSample: return TableSpec(sqlName: "hrSample", keyColumns: ["ts"], dataColumns: ["bpm"], booleanColumns: [])
        case .rrInterval: return TableSpec(sqlName: "rrInterval", keyColumns: ["ts", "rrMs", "seq"], dataColumns: ["ord", "srcChannel", "tsSuspect"], booleanColumns: ["tsSuspect"])
        case .rrPacketProvenance: return TableSpec(sqlName: "rrPacketProvenance", keyColumns: ["packetId"], dataColumns: ["ts", "sensorTs", "recordIndex", "rawHex", "srcChannel", "schemaVersion", "decoderVersion", "clockVersion", "timestampPrecisionSeconds", "clockOffsetSeconds", "declaredCount"], booleanColumns: [])
        case .standardHRReceipt: return TableSpec(sqlName: "standardHRReceipt", keyColumns: ["receiptId"], dataColumns: ["ts", "sessionId", "notificationOrdinal", "receivedUnixMs", "receivedMonotonicNs", "rawHex", "schemaVersion", "clockVersion"], booleanColumns: [])
        case .event: return TableSpec(sqlName: "event", keyColumns: ["ts", "kind"], dataColumns: ["payloadJSON"], booleanColumns: [])
        case .battery: return TableSpec(sqlName: "battery", keyColumns: ["ts"], dataColumns: ["soc", "mv", "charging"], booleanColumns: ["charging"])
        case .spo2Sample: return TableSpec(sqlName: "spo2Sample", keyColumns: ["ts"], dataColumns: ["red", "ir"], booleanColumns: [])
        case .skinTempSample: return TableSpec(sqlName: "skinTempSample", keyColumns: ["ts"], dataColumns: ["raw", "aux1Raw", "aux2Raw"], booleanColumns: [])
        case .respSample: return TableSpec(sqlName: "respSample", keyColumns: ["ts"], dataColumns: ["raw"], booleanColumns: [])
        case .gravitySample: return TableSpec(sqlName: "gravitySample", keyColumns: ["ts"], dataColumns: ["x", "y", "z", "dynAccel"], booleanColumns: [])
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

    private func appendRecord(row: Row, spec: TableSpec) -> PushAppendRecord {
        let rowId = row["_pushRowId"] as Int64
        let key = Dictionary(uniqueKeysWithValues: spec.keyColumns.map {
            ($0, pushValue(row: row, column: $0, boolean: spec.booleanColumns.contains($0)))
        })
        let data = Dictionary(uniqueKeysWithValues: spec.dataColumns.map {
            ($0, pushValue(row: row, column: $0, boolean: spec.booleanColumns.contains($0)))
        })
        return PushAppendRecord(rowId: rowId, key: key, data: data)
    }

    private func pushValue(row: Row, column: String, boolean: Bool) -> PushJSONValue {
        let dbValue: DatabaseValue = row[column]
        if dbValue.isNull { return .null }
        // JSON numbers lose nanosecond identity after ~104 days of system uptime. The receipt
        // wire contract uses a decimal string and the receiver stores it as an exact bigint.
        if column == "receivedMonotonicNs", let v = Int64.fromDatabaseValue(dbValue) { return .string(String(v)) }
        if boolean, let v = Int64.fromDatabaseValue(dbValue) { return .bool(v != 0) }
        if let v = Int64.fromDatabaseValue(dbValue) { return .int(v) }
        if let v = Double.fromDatabaseValue(dbValue) { return .double(v) }
        if let v = String.fromDatabaseValue(dbValue) { return .string(v) }
        if let v = Bool.fromDatabaseValue(dbValue) { return .bool(v) }
        return .null
    }
}
