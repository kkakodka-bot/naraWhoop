import Foundation
import GRDB

/// Closed source-table names for the mutable cloud replacement lane.
public enum CloudMutableTable: String, CaseIterable, Sendable {
    case dailyMetric, journal, sleepSession, workout
    fileprivate var usesDayKey: Bool { self == .dailyMetric || self == .journal }
}

public struct CloudMutableDirtyRange: Equatable, Sendable {
    public let revision: Int64
    public let key: String
    public let fromDay: String
    public let toDay: String
}

public struct CloudMutableDirtyPage: Equatable, Sendable {
    public let ranges: [CloudMutableDirtyRange]
    public let hasMore: Bool
}

extension WhoopStore {
    /// Each receiver advances its own consumed tuple only with an exact receipt. Coalescing
    /// moves a changed key to a newer revision, so mutations during an upload reappear. The key
    /// breaks ties when one source transaction moves a row across two dates.
    public nonisolated static func cloudMutableDirtyRanges(
        _ db: Database, table: CloudMutableTable, deviceID: String,
        afterRevision: Int64, afterKey: String, limit: Int, calendar: Calendar
    ) throws -> CloudMutableDirtyPage {
        guard !deviceID.isEmpty, afterRevision >= 0, (1...32).contains(limit) else {
            throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "Invalid mutable dirty range cursor")
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT revision,rangeKey FROM cloudMutableRevision
            WHERE tableName=? AND deviceId=? AND (revision,rangeKey) > (?,?)
            ORDER BY revision,rangeKey LIMIT ?
            """, arguments: [table.rawValue, deviceID, afterRevision, afterKey, limit + 1])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        formatter.isLenient = false
        func validDay(_ value: String) -> Bool {
            guard value.utf8.count == 10, let date = formatter.date(from: value) else { return false }
            return formatter.string(from: date) == value
        }
        let ranges = try rows.prefix(limit).map { row -> CloudMutableDirtyRange in
            let revision: Int64 = row["revision"], key: String = row["rangeKey"]
            let from: String, to: String
            if table.usesDayKey {
                guard key.hasPrefix("d:") else {
                    throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "Invalid mutable day marker")
                }
                from = String(key.dropFirst(2)); to = from
            } else {
                guard key.hasPrefix("u:"), let bucket = Int64(key.dropFirst(2)),
                      bucket >= 0, bucket <= 2_932_896, key == "u:\(bucket)" else {
                    throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "Invalid mutable timestamp marker")
                }
                from = formatter.string(from: Date(timeIntervalSince1970: Double(bucket) * 86400))
                to = formatter.string(from: Date(timeIntervalSince1970: Double(bucket + 1) * 86400 - 1))
            }
            guard revision > 0, validDay(from), validDay(to), from <= to else {
                throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "Invalid mutable marker range")
            }
            return .init(revision: revision, key: key, fromDay: from, toDay: to)
        }
        return .init(ranges: ranges, hasMore: rows.count > limit)
    }

    /// Coalesced revisions live in the same account database and source transaction. No source
    /// scan is needed on migration: an absent legacy marker means revision zero, and a receiver
    /// without a saved revision still needs its ordinary initial snapshot.
    nonisolated static func installCloudMutableJournal(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE cloudMutableSequence (
                singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton=1),
                revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>=0));
            INSERT INTO cloudMutableSequence VALUES(1,0);
            CREATE TABLE cloudMutableRevision (
                tableName TEXT NOT NULL, deviceId TEXT NOT NULL, rangeKey TEXT NOT NULL,
                revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
                PRIMARY KEY(tableName,deviceId,rangeKey));
            """)
        for table in CloudMutableTable.allCases {
            func marker(_ row: String) -> String {
                table.usesDayKey ? "'d:' || \(row).day" : "'u:' || CAST(\(row).startTs / 86400 AS INTEGER)"
            }
            func mark(_ row: String) -> String {
                """
                INSERT INTO cloudMutableRevision(tableName,deviceId,rangeKey,revision)
                VALUES('\(table.rawValue)',\(row).deviceId,\(marker(row)),
                       (SELECT revision FROM cloudMutableSequence WHERE singleton=1))
                ON CONFLICT(tableName,deviceId,rangeKey) DO UPDATE SET revision=excluded.revision;
                """
            }
            for operation in ["INSERT", "UPDATE", "DELETE"] {
                let rows = operation == "UPDATE" ? ["OLD", "NEW"] : [operation == "INSERT" ? "NEW" : "OLD"]
                try db.execute(sql: """
                    CREATE TRIGGER cloudMutable_\(table.rawValue)_\(operation.lowercased())
                    AFTER \(operation) ON \(table.rawValue) BEGIN
                        UPDATE cloudMutableSequence SET revision=revision+1 WHERE singleton=1;
                        \(rows.map(mark).joined(separator: "\n"))
                        INSERT INTO syncJob(kind,owedAt,token,attempts,lastNote)
                        VALUES('cloudPush',CAST(strftime('%s','now') AS INTEGER),
                               'mutable:' || (SELECT revision FROM cloudMutableSequence WHERE singleton=1),
                               0,'mutable source changed')
                        ON CONFLICT(kind) DO UPDATE SET owedAt=MIN(owedAt,excluded.owedAt),
                            token=excluded.token,attempts=0,lastNote=excluded.lastNote;
                    END;
                    """)
            }
        }
    }

    /// Read this before materializing source rows, and save the captured values only with exact
    /// receipt settlement. A later mutation then differs on the next pass. Timestamp sources use
    /// UTC-day buckets; a local day conservatively includes both intersecting buckets. This may
    /// re-read an adjacent day but cannot hide a timezone or daylight-saving boundary mutation.
    /// Callers must bind saved revision maps to their calendar/timezone before skipping a read.
    public nonisolated static func cloudMutableDayRevisions(
        _ db: Database, table: CloudMutableTable, deviceID: String,
        fromDay: String, toDay: String, calendar: Calendar
    ) throws -> [String: Int64] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        formatter.isLenient = false
        guard !deviceID.isEmpty, let start = formatter.date(from: fromDay),
              let end = formatter.date(from: toDay), start <= end,
              formatter.string(from: start) == fromDay, formatter.string(from: end) == toDay else {
            throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "Invalid mutable revision range")
        }
        var mapping: [String: [String]] = [:]
        var current = start
        while current <= end {
            guard mapping.count < 32, let next = calendar.date(byAdding: .day, value: 1, to: current),
                  next > current else {
                throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "Mutable revision range exceeds bound")
            }
            let day = formatter.string(from: current)
            if table.usesDayKey { mapping[day] = ["d:" + day] }
            else {
                let first = Int64(current.timeIntervalSince1970) / 86400
                let last = (Int64(next.timeIntervalSince1970) - 1) / 86400
                guard first >= 0, last >= first, last - first <= 2 else {
                    throw DatabaseError(resultCode: .SQLITE_MISUSE, message: "Invalid mutable timestamp range")
                }
                mapping[day] = (first...last).map { "u:\($0)" }
            }
            current = next
        }
        let keys = Array(Set(mapping.values.flatMap { $0 })).sorted()
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let values = try Row.fetchAll(db, sql: """
            SELECT rangeKey,revision FROM cloudMutableRevision
            WHERE tableName=? AND deviceId=? AND rangeKey IN (\(placeholders))
            """, arguments: StatementArguments([table.rawValue, deviceID] + keys))
        let byKey = Dictionary(uniqueKeysWithValues: values.map { (($0["rangeKey"] as String), ($0["revision"] as Int64)) })
        return mapping.mapValues { $0.compactMap { byKey[$0] }.max() ?? 0 }
    }
}
