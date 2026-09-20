package com.noop.data

import java.sql.DriverManager
import org.junit.Assert.*
import org.junit.Test

class PpgRecordIdentityMigrationTest {
    @Test fun migrationPreservesRowIdsBytesAndMultipleRecordsPerSecond() {
        DriverManager.getConnection("jdbc:sqlite::memory:").use { db ->
            db.createStatement().use { sql ->
                sql.execute("CREATE TABLE ppgWaveformSample(deviceId TEXT NOT NULL, ts INTEGER NOT NULL, " +
                    "samples BLOB NOT NULL, burstIndex INTEGER, PRIMARY KEY(deviceId,ts))")
                sql.execute("INSERT INTO ppgWaveformSample(rowid,deviceId,ts,samples,burstIndex) VALUES(88,'d',123,X'0100ff7f',14)")
                WhoopDatabase.PPG_RECORD_IDENTITY_MIGRATION_SQL.forEach(sql::execute)
                sql.executeQuery("SELECT rowid,samples,recordIndex FROM ppgWaveformSample").use {
                    assertTrue(it.next())
                    assertEquals(88L, it.getLong(1))
                    assertArrayEquals(byteArrayOf(1,0,-1,127), it.getBytes(2))
                    assertEquals(-1L, it.getLong(3))
                }
                repeat(2) {
                    sql.execute("INSERT OR IGNORE INTO ppgWaveformSample VALUES('d',123,X'0200',14,4294967295)")
                    sql.execute("INSERT OR IGNORE INTO ppgWaveformSample VALUES('d',123,X'0300',14,0)")
                }
                sql.executeQuery("SELECT count(*) FROM ppgWaveformSample").use {
                    assertTrue(it.next()); assertEquals(3, it.getInt(1))
                }
            }
        }
    }
}
