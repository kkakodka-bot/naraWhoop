import Foundation
import GRDB

/// The production SQLite cloud sources. File-backed IMU membership has its own durable index.
public enum CloudSourceTable: String, CaseIterable, Sendable {
    case hrSample, rrInterval, event, battery, spo2Sample, skinTempSample, respSample, gravitySample
    case stepSample, sleepStateSample, ppgHrSample
    case dailyMetric, journal, sleepSession, workout
    case ppgWaveformSample, v18AuxSample, rawBatch

    private var usesDayKey: Bool { self == .dailyMetric || self == .journal }
    fileprivate var mutableColumn: String? {
        if usesDayKey { return "day" }
        return self == .sleepSession || self == .workout ? "startTs" : nil
    }
    fileprivate var rangeExpression: String? {
        guard mutableColumn != nil else { return nil }
        return usesDayKey ? "'d:' || day" : "'u:' || CAST(startTs / 86400 AS INTEGER)"
    }
}

public struct CloudSourceMembershipSnapshot: Equatable, Sendable {
    public let deviceIDs: [String]
    /// False means unseen legacy source rows may remain. It is never evidence of empty debt.
    public let isComplete: Bool
}

public struct CloudSourceBootstrapProgress: Equatable, Sendable {
    public let rowsRead: Int
    public let isComplete: Bool
}

extension WhoopStore {
    nonisolated static func installCloudSourceMembership(_ db: Database) throws {
        let allowed = CloudSourceTable.allCases.map { "'\($0.rawValue)'" }.joined(separator: ",")
        try db.execute(sql: """
            CREATE TABLE cloudSourceMembership (
                tableName TEXT NOT NULL CHECK(tableName IN (\(allowed))),
                deviceId TEXT NOT NULL CHECK(length(deviceId)>0),
                PRIMARY KEY(tableName,deviceId));
            CREATE TABLE cloudSourceBootstrap (
                tableName TEXT NOT NULL PRIMARY KEY CHECK(tableName IN (\(allowed))),
                lastRowId INTEGER CHECK(lastRowId IS NULL OR typeof(lastRowId)='integer'),
                complete INTEGER NOT NULL DEFAULT 0 CHECK(complete IN (0,1)));
            """)
        for table in CloudSourceTable.allCases {
            try db.execute(sql: "INSERT INTO cloudSourceBootstrap(tableName) VALUES(?)", arguments: [table.rawValue])
            for operation in ["INSERT", "UPDATE", "DELETE"] {
                let rows = operation == "UPDATE" ? ["OLD", "NEW"] : [operation == "INSERT" ? "NEW" : "OLD"]
                let retain = rows.map { row in
                    """
                    INSERT INTO cloudSourceMembership(tableName,deviceId)
                    SELECT '\(table.rawValue)',\(row).deviceId WHERE length(\(row).deviceId)>0
                    ON CONFLICT(tableName,deviceId) DO NOTHING;
                    """
                }.joined(separator: "\n")
                try db.execute(sql: """
                    CREATE TRIGGER cloudSource_\(table.rawValue)_\(operation.lowercased())
                    AFTER \(operation) ON \(table.rawValue) BEGIN \(retain) END;
                    """)
            }
        }
    }

    /// Reads compact retained membership, never source payloads or broad source DISTINCT scans.
    /// Deletion identities remain here so an empty mutable replacement can still be delivered.
    public nonisolated static func cloudSourceMembership(
        _ db: Database, tables: Set<CloudSourceTable>
    ) throws -> CloudSourceMembershipSnapshot {
        guard !tables.isEmpty else { return .init(deviceIDs: [], isComplete: true) }
        let names = tables.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ",")
        let completed = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM cloudSourceBootstrap WHERE tableName IN (\(placeholders)) AND complete=1
            """, arguments: StatementArguments(names)) ?? 0
        let ids = try String.fetchAll(db, sql: """
            SELECT deviceId FROM cloudSourceMembership WHERE tableName IN (\(placeholders))
            GROUP BY deviceId ORDER BY deviceId
            """, arguments: StatementArguments(names))
        return .init(deviceIDs: ids, isComplete: completed == names.count)
    }

    /// Call inside a pressure-admitted write transaction, then commit before deferring an
    /// incomplete wake. Migration only installs metadata/triggers; this keyset scan discovers
    /// at most 2,000 legacy rows per call and reads identity/day columns, never blob payloads.
    /// Triggers capture inserts, deletes and identity/rowid moves behind the saved cursor.
    public nonisolated static func advanceCloudSourceBootstrap(
        _ db: Database, tables: Set<CloudSourceTable>, maximumRows: Int = 2000
    ) throws -> CloudSourceBootstrapProgress {
        guard db.isInsideTransaction, (1...2000).contains(maximumRows) else {
            throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "Cloud membership bootstrap needs a bounded write transaction")
        }
        var read = 0
        var seededRevision: Int64?
        for table in tables.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard read < maximumRows else { break }
            guard let progress = try Row.fetchOne(db, sql: "SELECT lastRowId,complete FROM cloudSourceBootstrap WHERE tableName=?",
                                                 arguments: [table.rawValue]) else {
                throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "Cloud membership bootstrap metadata missing")
            }
            if progress["complete"] as Int == 1 { continue }
            let last: Int64? = progress["lastRowId"]
            let predicate = last == nil ? "" : "WHERE rowid>?"
            let extra = table.rangeExpression.map { ",\($0) AS rangeKey" } ?? ""
            var arguments: StatementArguments = last.map { [$0] } ?? []
            arguments += [maximumRows - read]
            let rows = try Row.fetchAll(db, sql: """
                SELECT rowid AS sourceRowId,deviceId\(extra) FROM \(table.rawValue)
                \(predicate) ORDER BY rowid LIMIT ?
                """, arguments: arguments)
            let finished = rows.count < maximumRows - read
            read += rows.count
            var devices = Set<String>()
            var ranges: [String: Set<String>] = [:]
            for row in rows {
                let device: String = row["deviceId"]
                guard !device.isEmpty else { continue }
                if devices.insert(device).inserted {
                    try db.execute(sql: "INSERT INTO cloudSourceMembership(tableName,deviceId) VALUES(?,?) ON CONFLICT(tableName,deviceId) DO NOTHING",
                                   arguments: [table.rawValue, device])
                }
                if table.mutableColumn != nil {
                    let key: String = row["rangeKey"]
                    guard ranges[device, default: []].insert(key).inserted else { continue }
                    if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM cloudMutableRevision WHERE tableName=? AND deviceId=? AND rangeKey=?)",
                                         arguments: [table.rawValue,device,key]) == false {
                        if seededRevision == nil {
                            try db.execute(sql: "UPDATE cloudMutableSequence SET revision=revision+1 WHERE singleton=1")
                            seededRevision = try Int64.fetchOne(db, sql: "SELECT revision FROM cloudMutableSequence WHERE singleton=1")
                        }
                        guard let revision = seededRevision, revision > 0 else {
                            throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "Cloud mutable revision unavailable")
                        }
                        try db.execute(sql: """
                            INSERT INTO cloudMutableRevision(tableName,deviceId,rangeKey,revision) VALUES(?,?,?,?)
                            ON CONFLICT(tableName,deviceId,rangeKey) DO NOTHING
                            """, arguments: [table.rawValue,device,key,revision])
                    }
                }
            }
            try db.execute(sql: "UPDATE cloudSourceBootstrap SET lastRowId=?,complete=? WHERE tableName=?",
                           arguments: [rows.last.map { $0["sourceRowId"] as Int64 } ?? last, finished ? 1 : 0, table.rawValue])
        }
        if read > 0 {
            try db.execute(sql: """
                INSERT INTO syncJob(kind,owedAt,token,attempts,lastNote) VALUES('cloudPush',CAST(strftime('%s','now') AS INTEGER),?,0,'source membership bootstrap')
                ON CONFLICT(kind) DO UPDATE SET owedAt=MIN(owedAt,excluded.owedAt),token=excluded.token,attempts=0,lastNote=excluded.lastNote
                """, arguments: ["bootstrap:" + UUID().uuidString.lowercased()])
        }
        return .init(rowsRead: read, isComplete: try cloudSourceMembership(db, tables: tables).isComplete)
    }
}
