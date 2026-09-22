import Foundation
import GRDB

public enum V18AuxIdentitySchemaError: Error, Equatable {
    case transactionRequired
    case unexpectedSchema
    case ledgerMismatch
    case copyMismatch
}

extension WhoopStore {
    /// Root registers this once as v51. No capture-time schema repair or owner adoption.
    public nonisolated static func installV18AuxIdentitySchema(_ db: Database) throws {
        guard db.isInsideTransaction else { throw V18AuxIdentitySchemaError.transactionRequired }
        guard Set(try db.columns(in: "v18AuxSample").map(\.name)) == ["deviceId", "ts", "fields"],
              try db.primaryKey("v18AuxSample").columns == ["deviceId", "ts"],
              try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM v18AuxSample
                WHERE typeof(deviceId) != 'text' OR typeof(ts) != 'integer' OR typeof(fields) != 'blob'
                """) == 0 else { throw V18AuxIdentitySchemaError.unexpectedSchema }
        try db.execute(sql: """
            CREATE TABLE v18AuxSample_v51 (
                deviceId TEXT NOT NULL,
                ts INTEGER NOT NULL,
                recordIndex INTEGER NOT NULL
                    CHECK (typeof(recordIndex) = 'integer' AND recordIndex BETWEEN -1 AND 4294967295),
                fields BLOB NOT NULL,
                resourceKey TEXT NOT NULL CHECK (length(resourceKey) > 0),
                PRIMARY KEY (deviceId, ts, recordIndex));
            """)
        let hasLedger = try db.tableExists("ingestRawResource")
        let insert = try db.makeStatement(sql: """
            INSERT INTO v18AuxSample_v51(rowid, deviceId, ts, recordIndex, fields, resourceKey)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        var after: Int64?
        while true {
            let rows: [Row]
            if let after {
                rows = try Row.fetchAll(db, sql: """
                    SELECT rowid, deviceId, ts, fields FROM v18AuxSample
                    WHERE rowid > ? ORDER BY rowid LIMIT 512
                    """, arguments: [after])
            } else {
                rows = try Row.fetchAll(db, sql: """
                    SELECT rowid, deviceId, ts, fields FROM v18AuxSample ORDER BY rowid LIMIT 512
                    """)
            }
            guard !rows.isEmpty else { break }
            for row in rows {
                let rowID: Int64 = row["rowid"]
                let device: String = row["deviceId"]
                let ts: Int64 = row["ts"]
                let bytes: Data = row["fields"]
                let key = String(ts)
                if hasLedger, let ledger = try Row.fetchOne(db, sql: """
                    SELECT contentSHA256, byteCount FROM ingestRawResource
                    WHERE lane = 'v18AuxSample' AND deviceId = ? AND resourceKey = ?
                    """, arguments: [device, key]) {
                    guard (ledger["contentSHA256"] as String) == DurableIngestScope.sha256(bytes),
                          (ledger["byteCount"] as Int) == bytes.count else {
                        throw V18AuxIdentitySchemaError.ledgerMismatch
                    }
                }
                try insert.execute(arguments: [rowID, device, ts,
                    V18AuxCodec.strictRecordIndex(in: bytes) ?? -1, bytes, key])
                after = rowID
            }
        }
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v18AuxSample") ==
                Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v18AuxSample_v51"),
              try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM v18AuxSample o LEFT JOIN v18AuxSample_v51 n ON n.rowid = o.rowid
                WHERE n.rowid IS NULL OR n.deviceId != o.deviceId OR n.ts != o.ts
                    OR n.fields != o.fields OR n.resourceKey != CAST(o.ts AS TEXT)
                """) == 0 else { throw V18AuxIdentitySchemaError.copyMismatch }
        try db.execute(sql: """
            DROP TABLE v18AuxSample;
            ALTER TABLE v18AuxSample_v51 RENAME TO v18AuxSample;
            CREATE UNIQUE INDEX index_v18AuxSample_deviceId_resourceKey
                ON v18AuxSample(deviceId, resourceKey);
            """)
    }
}
