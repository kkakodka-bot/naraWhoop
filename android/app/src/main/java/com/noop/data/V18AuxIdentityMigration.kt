package com.noop.data

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import java.security.MessageDigest

internal object V18AuxIdentityMigration : Migration(40, 41) {
    override fun migrate(db: SupportSQLiteDatabase) {
        check(db.inTransaction()) { "Auxiliary migration requires a transaction" }
        val columns = linkedMapOf<String, Int>()
        db.query("PRAGMA table_info(v18AuxSample)").use { while (it.moveToNext()) columns[it.getString(1)] = it.getInt(5) }
        check(columns == linkedMapOf("deviceId" to 1, "ts" to 2, "fields" to 0))
        check(count(db, "SELECT COUNT(*) FROM v18AuxSample WHERE typeof(deviceId)!='text' OR typeof(ts)!='integer' OR typeof(fields)!='blob'") == 0L)
        db.execSQL("""CREATE TABLE v18AuxSample_v41(deviceId TEXT NOT NULL,ts INTEGER NOT NULL,
            recordIndex INTEGER NOT NULL CHECK(typeof(recordIndex)='integer' AND recordIndex BETWEEN -1 AND 4294967295),
            fields BLOB NOT NULL,resourceKey TEXT NOT NULL CHECK(length(resourceKey)>0),PRIMARY KEY(deviceId,ts,recordIndex))""")
        val hasLedger = count(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='ingestRawResource'") == 1L
        var after: Long? = null
        while (true) {
            val query = if (after == null) "SELECT rowid,deviceId,ts,fields FROM v18AuxSample ORDER BY rowid LIMIT 512"
                else "SELECT rowid,deviceId,ts,fields FROM v18AuxSample WHERE rowid>? ORDER BY rowid LIMIT 512"
            var seen = false
            db.query(query, if (after == null) emptyArray() else arrayOf(after!!)).use { rows ->
                while (rows.moveToNext()) {
                    seen = true
                    val rowId = rows.getLong(0); val device = rows.getString(1); val ts = rows.getLong(2); val fields = rows.getBlob(3)
                    val key = ts.toString()
                    if (hasLedger) db.query("SELECT contentSHA256,byteCount FROM ingestRawResource WHERE lane='v18AuxSample' AND deviceId=? AND resourceKey=?",
                        arrayOf(device, key)).use { ledger ->
                        while (ledger.moveToNext()) check(ledger.getString(0) == sha256(fields) && ledger.getLong(1) == fields.size.toLong()) {
                            "Auxiliary resource digest mismatch"
                        }
                    }
                    db.execSQL("INSERT INTO v18AuxSample_v41(rowid,deviceId,ts,recordIndex,fields,resourceKey) VALUES(?,?,?,?,?,?)",
                        arrayOf(rowId, device, ts, V18AuxIdentity.complete(fields)?.recordIndex ?: -1L, fields, key))
                    after = rowId
                }
            }
            if (!seen) break
        }
        check(count(db, "SELECT COUNT(*) FROM v18AuxSample") == count(db, "SELECT COUNT(*) FROM v18AuxSample_v41"))
        check(count(db, """SELECT COUNT(*) FROM v18AuxSample o LEFT JOIN v18AuxSample_v41 n ON n.rowid=o.rowid
            WHERE n.rowid IS NULL OR n.deviceId!=o.deviceId OR n.ts!=o.ts OR n.fields!=o.fields OR n.resourceKey!=CAST(o.ts AS TEXT)""") == 0L)
        db.execSQL("DROP TABLE v18AuxSample")
        db.execSQL("ALTER TABLE v18AuxSample_v41 RENAME TO v18AuxSample")
        db.execSQL("CREATE UNIQUE INDEX index_v18AuxSample_deviceId_resourceKey ON v18AuxSample(deviceId,resourceKey)")
        installGuards(db)
    }

    fun installGuards(db: SupportSQLiteDatabase) {
        for (event in listOf("INSERT", "UPDATE")) db.execSQL("""CREATE TRIGGER v18Aux_identity_${event.lowercase()} BEFORE $event ON v18AuxSample
            WHEN typeof(NEW.recordIndex)!='integer' OR NEW.recordIndex NOT BETWEEN -1 AND 4294967295 OR length(NEW.resourceKey)=0
            BEGIN SELECT RAISE(ABORT,'Invalid auxiliary identity'); END""")
    }
    private fun count(db: SupportSQLiteDatabase, sql: String): Long = db.query(sql).use { check(it.moveToFirst()); it.getLong(0) }
    fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
