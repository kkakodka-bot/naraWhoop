package com.noop.data

import java.sql.Connection
import java.sql.DriverManager
import org.junit.Assert.*
import org.junit.Test

class WearEventsForWindowTest {
    private fun database(): Connection = DriverManager.getConnection("jdbc:sqlite::memory:").also { db ->
        db.createStatement().use {
            it.execute("CREATE TABLE event(deviceId TEXT NOT NULL,ts INTEGER NOT NULL,kind TEXT NOT NULL," +
                "payloadJSON TEXT NOT NULL DEFAULT '{}',synced INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(deviceId,ts,kind))")
        }
    }

    private fun read(db: Connection, start: Long, endExclusive: Long): List<Pair<Long, String>> =
        db.prepareStatement(WEAR_EVENTS_FOR_WINDOW_SQL).use { query ->
            query.setString(1, "d")
            query.setLong(2, endExclusive)
            query.setLong(3, start)
            query.executeQuery().use { rows -> buildList {
                while (rows.next()) add(rows.getLong("ts") to rows.getString("kind"))
            } }
        }

    @Test fun seedsLastPriorStateAndKeepsOnlyOwnedHalfOpenWindowTransitions() {
        database().use { db ->
            db.createStatement().use { sql ->
                sql.execute("INSERT INTO event(deviceId,ts,kind) VALUES " +
                    "('d',-10000,'WRIST_ON(11)'),('d',-5000,'WRIST_OFF(10)')," +
                    "('d',120,'WRIST_ON(11)'),('d',180,'WRIST_OFF(10)'),('d',300,'WRIST_ON(11)')," +
                    "('d',99,'STANDARD_HR_CONTACT'),('other',-1,'WRIST_ON(11)'),('other',150,'WRIST_OFF(10)')")
            }
            assertEquals(listOf(-5000L to "WRIST_OFF(10)", 120L to "WRIST_ON(11)", 180L to "WRIST_OFF(10)"),
                read(db, 0, 300))
        }
    }

    @Test fun denseUnrelatedEventsCannotTruncateWearHistory() {
        database().use { db ->
            db.createStatement().use { sql ->
                sql.execute("WITH RECURSIVE seconds(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM seconds WHERE n<100100) " +
                    "INSERT INTO event(deviceId,ts,kind) SELECT 'd',n,'STANDARD_HR_CONTACT' FROM seconds")
                sql.execute("INSERT INTO event(deviceId,ts,kind) VALUES ('d',10,'WRIST_OFF(10)'),('d',100099,'WRIST_ON(11)')")
            }
            assertEquals(listOf(10L to "WRIST_OFF(10)", 100099L to "WRIST_ON(11)"), read(db, 99900, 100200))
        }
    }

    @Test fun absentWearEvidenceStaysEmpty() {
        database().use { db ->
            db.createStatement().use { it.execute("INSERT INTO event(deviceId,ts,kind) VALUES ('other',100,'WRIST_ON(11)')") }
            assertTrue(read(db, 0, 300).isEmpty())
        }
    }
}
