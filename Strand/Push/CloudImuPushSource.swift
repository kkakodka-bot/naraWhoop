import Foundation
import GRDB
import NoopPush

/// Two captured stores, one durable row-ID namespace. Timestamps never deduplicate windows/stores.
/// This indexes physiology-row receipts only. Exact .imus archives have a separate pruning gate.
final class CloudImuPushSource: ImuSessionPushSource, @unchecked Sendable {
    let scope: AccountScope
    let stores: [String: ImuSessionFileStore]
    let index: DatabaseQueue
    let isolation = NSLock()
    let segmentBudget: Int
    let maximumArchiveBytes: Int

    init(scope: AccountScope, directory: URL, sessionStore: ImuSessionFileStore,
         continuousStore: ImuSessionFileStore, segmentBudget: Int = 16,
         maximumArchiveBytes: Int = 32 * 1_048_576) throws {
        guard sessionStore.pushOwnerMatches(scope), continuousStore.pushOwnerMatches(scope), segmentBudget > 0, maximumArchiveBytes > 0 else {
            throw ImuPushSourceError.staleOwner
        }
        self.scope = scope; self.stores = ["session": sessionStore, "continuous": continuousStore]
        self.segmentBudget = min(16, segmentBudget)
        self.maximumArchiveBytes = min(32 * 1_048_576, maximumArchiveBytes)
        _ = try CloudUploadJournal(directory: directory)
        var config = Configuration()
        config.prepareDatabase {
            try $0.execute(sql: "PRAGMA synchronous = FULL")
            // New indexes support bounded page reclamation; older indexes reuse their freelist.
            if try Int.fetchOne($0, sql: "PRAGMA page_count") == 0 { try $0.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL") }
            let pageSize = try Int.fetchOne($0, sql: "PRAGMA page_size") ?? 4096
            try $0.execute(sql: "PRAGMA max_page_count = \(128 * 1_048_576 / pageSize)")
        }
        index = try DatabaseQueue(path: directory.appendingPathComponent("membership.sqlite").path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_owner_and_imu_membership") { db in
            try db.execute(sql: """
                CREATE TABLE owner (id INTEGER PRIMARY KEY CHECK(id = 1), namespace TEXT NOT NULL);
                CREATE TABLE member (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, device TEXT NOT NULL, origin TEXT NOT NULL,
                    window TEXT NOT NULL, bucket INTEGER NOT NULL, ts INTEGER NOT NULL,
                    digest TEXT NOT NULL, segmentDigest TEXT NOT NULL,
                    UNIQUE(device, origin, window, bucket, ts, digest));
                CREATE INDEX member_device ON member(device, id);
                CREATE TABLE rowReceipt (memberID INTEGER PRIMARY KEY REFERENCES member(id), receipt BLOB NOT NULL);
                CREATE TABLE scan (device TEXT PRIMARY KEY, lastKey TEXT NOT NULL);
                """)
        }
        migrator.registerMigration("v2_scan_completion") { db in
            try db.execute(sql: "ALTER TABLE scan ADD COLUMN inProgress INTEGER NOT NULL DEFAULT 0")
        }
        Self.addArchiveMigration(to: &migrator)
        try migrator.migrate(index)
        try index.write { db in
            if let owner = try String.fetchOne(db, sql: "SELECT namespace FROM owner WHERE id = 1") {
                guard owner == scope.namespace else { throw ImuPushSourceError.staleOwner }
            } else { try db.execute(sql: "INSERT INTO owner VALUES(1, ?)", arguments: [scope.namespace]) }
        }
    }

    func pushDeviceIds() -> Set<String> { stores.values.reduce(into: Set<String>()) { $0.formUnion($1.pushDeviceIds()) } }
    func pushRecords(deviceId: String, afterTs: Int64, limit: Int) -> [ImuPushRecord] {
        // This legacy API cannot represent the cursor. No production caller uses it on the mux.
        []
    }
    func indexedPushRecord(deviceId: String, rowId: Int64) throws -> ImuPushRecord? {
        isolation.lock(); defer { isolation.unlock() }
        guard let row = try index.read({ try Row.fetchOne($0, sql: "SELECT * FROM member WHERE device = ? AND id = ?", arguments: [deviceId, rowId]) }) else {
            return try anchor(deviceID: deviceId, rowID: rowId)
        }
        return try materialize([row]).first
    }
    func indexedPushRows(deviceId: String, afterRowId: Int64, limit: Int) throws -> [ImuPushRecord] {
        isolation.lock(); defer { isolation.unlock() }
        guard limit > 0, limit <= PushProtocolLimits.maxRecords + 1 else { throw ImuPushSourceError.membershipUnavailable }
        func pendingRows() throws -> [Row] {
            try index.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM member WHERE device = ? AND id > ? ORDER BY id LIMIT ?",
                                 arguments: [deviceId, afterRowId, limit])
            }
        }
        let scanning = try index.read { try Bool.fetchOne($0, sql: "SELECT inProgress FROM scan WHERE device = ?", arguments: [deviceId]) } ?? false
        // Drain an already inventoried page without restarting a long scan on each upload.
        if !scanning {
            let rows = try pendingRows()
            if !rows.isEmpty { return try materialize(rows) }
        }
        // Do not report noData/hasMore=false halfway through a bounded inventory. The saved scan
        // resumes after relaunch; the coordinator retains debt while this retryable state exists.
        if try scan(deviceID: deviceId) { throw ImuPushSourceError.scanPending }
        return try materialize(pendingRows())
    }
    private func scan(deviceID: String) throws -> Bool {
        let segments = try stores.sorted { $0.key < $1.key }.flatMap { origin, store in
            try store.pushSegmentInventory(deviceID: deviceID).map { (origin, $0) }
        }
        func key(_ origin: String, _ segment: ImuPushSegment) -> String { "\(origin)/\(segment.windowID)/\(segment.bucket)" }
        let sorted = segments.sorted { key($0.0, $0.1) < key($1.0, $1.1) }
        let last = try index.read { try String.fetchOne($0, sql: "SELECT lastKey FROM scan WHERE device = ?", arguments: [deviceID]) } ?? ""
        let tail = sorted.filter { key($0.0, $0.1) > last }
        let selected = Array((tail.isEmpty ? sorted : tail).prefix(segmentBudget))
        let more = selected.count < (tail.isEmpty ? sorted.count : tail.count)
        for (origin, segment) in selected {
            let snapshot = try stores[origin]!.pushSegmentSnapshot(segment)
            try index.write { db in
                try indexSegment(db, origin: origin, segment: segment, snapshot: snapshot)
                try db.execute(sql: """
                    INSERT INTO scan(device, lastKey, inProgress) VALUES(?, ?, 1)
                    ON CONFLICT(device) DO UPDATE SET lastKey = excluded.lastKey, inProgress = 1
                    """, arguments: [deviceID, key(origin, segment)])
            }
        }
        if !more {
            try index.write { try $0.execute(sql: "UPDATE scan SET inProgress = 0 WHERE device = ?", arguments: [deviceID]) }
        }
        return more
    }
    private func materialize(_ members: [Row]) throws -> [ImuPushRecord] {
        // At most one decoded segment is retained, even when a row page spans many windows.
        var cachedKey: String?
        var cached: [Int64: Data] = [:]
        return try members.map { row in
            let origin: String = row["origin"], window: String = row["window"], bucket: Int64 = row["bucket"]
            let key = "\(origin)/\(window)/\(bucket)"
            if cachedKey != key {
                guard let store = stores[origin] else { throw ImuPushSourceError.membershipUnavailable }
                let snapshot = try store.pushSegmentSnapshot(.init(windowID: window, deviceID: row["device"], bucket: bucket))
                cached = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.ts, $0.columns) })
                cachedKey = key
            }
            let ts: Int64 = row["ts"]
            guard let columns = cached[ts], PushDurabilityReceipt.sha256(columns) == (row["digest"] as String) else {
                throw ImuPushSourceError.membershipUnavailable
            }
            return ImuPushRecord(ts: ts, columns: columns, rowId: row["id"])
        }
    }
    func associatePushReceipt(rows: [PushRawImuRecord], receipt: PushDurabilityReceipt, scope: AccountScope) throws {
        isolation.lock(); defer { isolation.unlock() }
        guard self.scope == scope, receipt.isValid, receipt.ownerUserId == scope.userID,
              receipt.stream == "rawImuSession", !rows.isEmpty else { throw ImuPushSourceError.staleOwner }
        let encoded = try JSONEncoder().encode(receipt)
        try index.write { db in
            for row in rows {
                guard let member = try Row.fetchOne(db, sql: "SELECT * FROM member WHERE id = ?", arguments: [row.rowId]),
                      (member["ts"] as Int64) == row.ts,
                      (member["digest"] as String) == PushDurabilityReceipt.sha256(row.columns),
                      receipt.deviceId == PushDurabilityReceipt.canonicalDevice(owner: scope.userID, device: member["device"]) else {
                    throw ImuPushSourceError.membershipUnavailable
                }
                try db.execute(sql: "INSERT INTO rowReceipt VALUES(?, ?) ON CONFLICT(memberID) DO NOTHING", arguments: [row.rowId, encoded])
            }
        }
    }
}
