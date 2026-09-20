package com.noop.data

import java.nio.file.Files
import java.security.MessageDigest
import java.sql.Connection
import java.sql.DriverManager
import org.junit.Assert.*
import org.junit.Test

class EnrollmentPairingMetadataTest {
    @Test fun upgradeCopiesPairingOnlyAndLeavesLegacyHealthBytesUnchanged() {
        Class.forName("org.sqlite.JDBC")
        val file = Files.createTempFile("legacy-enrollment", ".db").toFile()
        try {
            DriverManager.getConnection("jdbc:sqlite:${file.path}").use { db ->
                schema(db)
                execute(db, "INSERT INTO pairedDevice VALUES ('whoop-SERIAL', 'active', 'AA:BB')")
                execute(db, "INSERT INTO device VALUES ('whoop-SERIAL', 'strap')")
                execute(db, "INSERT INTO hrSample VALUES ('whoop-SERIAL', 123, 61)")
                execute(db, "INSERT INTO syncJob VALUES ('legacy-debt')")
            }
            val original = MessageDigest.getInstance("SHA-256").digest(file.readBytes())
            DriverManager.getConnection("jdbc:sqlite:file:${file.path}?mode=ro").use { source ->
                DriverManager.getConnection("jdbc:sqlite::memory:").use { target ->
                    schema(target)
                    execute(target, "INSERT INTO pairedDevice VALUES ('my-whoop', 'active', NULL)")
                    EnrollmentPairingMetadata.copy({ read(source, it) }, { sql, args -> execute(target, sql, args) })
                    assertEquals(listOf("whoop-SERIAL"), read(target, "SELECT id FROM pairedDevice").map { it["id"] })
                    assertEquals("AA:BB", read(target, "SELECT peripheralId FROM pairedDevice").single()["peripheralId"])
                    assertEquals("strap", read(target, "SELECT name FROM device").single()["name"])
                    assertTrue(read(target, "SELECT * FROM hrSample").isEmpty())
                    assertTrue(read(target, "SELECT * FROM syncJob").isEmpty())
                    assertEquals(61, read(source, "SELECT bpm FROM hrSample").single()["bpm"])
                }
            }
            assertArrayEquals(original, MessageDigest.getInstance("SHA-256").digest(file.readBytes()))
        } finally { file.delete() }
    }

    @Test fun emptyLegacyRegistryKeepsFreshInstallSeed() {
        DriverManager.getConnection("jdbc:sqlite::memory:").use { source ->
            DriverManager.getConnection("jdbc:sqlite::memory:").use { target ->
                schema(source); schema(target)
                execute(target, "INSERT INTO pairedDevice VALUES ('my-whoop', 'active', NULL)")
                EnrollmentPairingMetadata.copy({ read(source, it) }, { sql, args -> execute(target, sql, args) })
                assertEquals("my-whoop", read(target, "SELECT id FROM pairedDevice").single()["id"])
            }
        }
    }

    private fun schema(db: Connection) {
        execute(db, "CREATE TABLE pairedDevice (id TEXT PRIMARY KEY, status TEXT, peripheralId TEXT)")
        execute(db, "CREATE TABLE device (id TEXT PRIMARY KEY, name TEXT)")
        execute(db, "CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER)")
        execute(db, "CREATE TABLE syncJob (id TEXT)")
    }
    private fun read(db: Connection, sql: String): List<Map<String, Any?>> = db.createStatement().use { statement ->
        statement.executeQuery(sql).use { rows -> buildList {
            while (rows.next()) add((1..rows.metaData.columnCount).associate { i -> rows.metaData.getColumnName(i) to rows.getObject(i) })
        } }
    }
    private fun execute(db: Connection, sql: String, args: Array<Any?> = emptyArray()) {
        db.prepareStatement(sql).use { statement ->
            args.forEachIndexed { i, value -> statement.setObject(i + 1, value) }
            statement.executeUpdate()
        }
    }
}
