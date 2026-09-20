package com.noop.data

import java.sql.DriverManager
import org.junit.Assert.*
import org.junit.Test

class StandardHrReceiptMigrationTest {
    @Test fun additiveMigrationAndSameSecondReplayPreserveOriginalRecords() {
        DriverManager.getConnection("jdbc:sqlite::memory:").use { db -> db.createStatement().use { sql ->
            sql.execute("CREATE TABLE rrInterval(deviceId TEXT,ts INTEGER,rrMs INTEGER)")
            sql.execute("INSERT INTO rrInterval VALUES('d',1700000000,1000)")
            WhoopDatabase.STANDARD_HR_RECEIPT_MIGRATION_SQL.forEach(sql::execute)
            sql.executeQuery("SELECT COUNT(*) FROM rrInterval").use { it.next(); assertEquals(1,it.getInt(1)) }
            sql.executeQuery("SELECT COUNT(*) FROM standardHRReceipt").use { it.next(); assertEquals(0,it.getInt(1)) }
            val session = "11111111-2222-3333-4444-555555555555"
            for (ordinal in 0..2) repeat(2) {
                val p = com.noop.protocol.StandardHrReceipt.capture(byteArrayOf(0x10,60,0,4), session,
                    ordinal.toLong(), 1700000000123, ordinal.toLong())!!
                db.prepareStatement("INSERT OR IGNORE INTO standardHRReceipt VALUES(?,?,?,?,?,?,?,?,?,?)").use { stmt ->
                    stmt.setString(1,"d"); stmt.setString(2,p.receiptId); stmt.setLong(3,p.ts)
                    stmt.setString(4,p.sessionId); stmt.setLong(5,p.notificationOrdinal); stmt.setLong(6,p.receivedUnixMs)
                    stmt.setLong(7,p.receivedMonotonicNs); stmt.setString(8,p.rawHex); stmt.setInt(9,p.schemaVersion)
                    stmt.setString(10,p.clockVersion); stmt.executeUpdate()
                }
            }
            sql.executeQuery("SELECT COUNT(*),COUNT(DISTINCT ts) FROM standardHRReceipt").use {
                it.next(); assertEquals(3,it.getInt(1)); assertEquals(1,it.getInt(2))
            }
        } }
    }
}
