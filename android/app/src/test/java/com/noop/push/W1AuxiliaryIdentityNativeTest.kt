package com.noop.push

import android.app.Application
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import com.noop.data.*
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.UUID

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W1AuxiliaryIdentityNativeTest {
    private fun oldDb(name: String = "aux-${UUID.randomUUID()}.sqlite") = FrameworkSQLiteOpenHelperFactory().create(
        SupportSQLiteOpenHelper.Configuration.builder(RuntimeEnvironment.getApplication()).name(name)
            .callback(object : SupportSQLiteOpenHelper.Callback(1) {
                override fun onCreate(db: SupportSQLiteDatabase) {
                    db.execSQL("CREATE TABLE v18AuxSample(deviceId TEXT NOT NULL,ts INTEGER NOT NULL,fields BLOB NOT NULL,PRIMARY KEY(deviceId,ts))")
                }
                override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
            }).build())
    private fun migrate(db: SupportSQLiteDatabase) {
        db.beginTransaction()
        try { V18AuxIdentityMigration.migrate(db); db.setTransactionSuccessful() } finally { db.endTransaction() }
    }

    @Test fun migrationKeepsRowidsEveryBlobAndCompatibilityKeyAcrossPagesAndReopen() {
        val name = "aux-${UUID.randomUUID()}.sqlite"
        val valid = V18AuxIdentity.pack(V18AuxRow(1, recordIndex = 4294967295L, rrCount = 4))
        val blobs = listOf(valid, valid.copyOf(valid.size - 1), byteArrayOf(), byteArrayOf(9, 1, 0, 0, 0, 3),
            valid.copyOf().also { it[4] = 0x80.toByte() }, V18AuxIdentity.pack(V18AuxRow(1, rrCount = 0)))
        oldDb(name).use { helper ->
            val db = helper.writableDatabase
            repeat(520) { index -> db.execSQL("INSERT INTO v18AuxSample(rowid,deviceId,ts,fields) VALUES(?,?,?,?)",
                arrayOf(index.toLong() - 3, "fixture", 100L + index, blobs[index % blobs.size])) }
            migrate(db)
            db.query("SELECT rowid,ts,recordIndex,fields,resourceKey FROM v18AuxSample ORDER BY rowid").use { rows ->
                var index = 0
                while (rows.moveToNext()) {
                    assertEquals(index.toLong() - 3, rows.getLong(0)); assertEquals(100L + index, rows.getLong(1))
                    assertEquals(if (index % blobs.size == 0) 4294967295L else -1L, rows.getLong(2))
                    assertArrayEquals(blobs[index % blobs.size], rows.getBlob(3)); assertEquals((100L + index).toString(), rows.getString(4))
                    index++
                }
                assertEquals(520, index)
            }
        }
        oldDb(name).use { helper ->
            helper.readableDatabase.query("SELECT COUNT(*),COUNT(DISTINCT resourceKey) FROM v18AuxSample").use {
                assertTrue(it.moveToFirst()); assertEquals(520, it.getInt(0)); assertEquals(520, it.getInt(1))
            }
        }
    }

    @Test fun actualRoomOpenRunsFortyThroughCurrentAndValidatesAllTablesWithoutRebindingOwner() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            val schema = JSONObject(java.io.File(System.getProperty("room.schemaLocation"),
                "com.noop.data.WhoopDatabase/${WhoopDatabase.SCHEMA_VERSION}.json").readText()).getJSONObject("database")
            val fields = V18AuxIdentity.pack(V18AuxRow(100, recordIndex = 4294967295L))
            // All unchanged tables use the actual Room export. Only the four versioned tables are
            // restored to their explicit pre-41/42 shape and all Room43/44 additions are absent.
            // The real Room migrator must validate the complete current schema.
            android.database.sqlite.SQLiteDatabase.openOrCreateDatabase(account.getDatabasePath(WhoopDatabase.DB_NAME), null).use { sql ->
                sql.beginTransaction()
                try {
                    val entities = schema.getJSONArray("entities")
                    for (i in 0 until entities.length()) {
                        val entity = entities.getJSONObject(i); val name = entity.getString("tableName")
                        if (name in setOf("localCaptureResource", "localCaptureMember", "gpsWorkoutDelivery", "gpsDestinationBarrier")) continue
                        var create = entity.getString("createSql").replace("\${TABLE_NAME}", name)
                        if (name == "v18AuxSample") create = "CREATE TABLE v18AuxSample(deviceId TEXT NOT NULL,ts INTEGER NOT NULL,fields BLOB NOT NULL,PRIMARY KEY(deviceId,ts))"
                        if (name in setOf("stepSample", "sleepStateSample", "ppgHrSample")) create = create.replace(", `provenanceJSON` TEXT", "")
                        sql.execSQL(create)
                        if (name != "v18AuxSample") {
                            val indices = entity.getJSONArray("indices")
                            for (j in 0 until indices.length()) sql.execSQL(indices.getJSONObject(j).getString("createSql").replace("\${TABLE_NAME}", name))
                        }
                    }
                    sql.execSQL("CREATE TABLE localAccountOwner(singleton INTEGER PRIMARY KEY CHECK(singleton=1),projectURL TEXT NOT NULL,userID TEXT NOT NULL)")
                    sql.execSQL("INSERT INTO localAccountOwner VALUES(1,?,?)", arrayOf(f.owner.projectURL, f.owner.userID))
                    sql.execSQL("INSERT INTO v18AuxSample(rowid,deviceId,ts,fields) VALUES(77,?,100,?)", arrayOf(f.device, fields))
                    sql.execSQL("INSERT INTO stepSample(deviceId,ts,counter,activityClass,synced) VALUES(?,100,65535,NULL,0)", arrayOf(f.device))
                    sql.version = 40; sql.setTransactionSuccessful()
                } finally { sql.endTransaction() }
            }
            val migrated = WhoopDatabase.get(account)
            val aux = migrated.whoopDao().v18AuxIdentity(f.device, 100, 4294967295L)!!
            assertEquals("100", aux.resourceKey); assertArrayEquals(fields, aux.fields)
            assertNull(migrated.whoopDao().stepSamples(f.device, 0, 200, 10).single().provenanceJSON)
            migrated.openHelper.readableDatabase.query("SELECT rowid FROM v18AuxSample").use {
                assertTrue(it.moveToFirst()); assertEquals(77, it.getLong(0))
            }
            assertEquals(WhoopDatabase.SCHEMA_VERSION, migrated.openHelper.readableDatabase.version)
            for (table in listOf("localCaptureResource", "localCaptureMember", "gpsWorkoutDelivery", "gpsDestinationBarrier")) {
                migrated.openHelper.readableDatabase.query("SELECT COUNT(*) FROM $table").use {
                    assertTrue(it.moveToFirst()); assertEquals(0, it.getInt(0))
                }
            }
            WhoopDatabase.close()
            assertTrue(runCatching { WhoopDatabase.get(account) }.exceptionOrNull() is
                com.noop.account.AccountWriteRevokedException)
            // A process-teardown close retires that generation. Reopening the same durable
            // namespace requires a fresh authorized generation, not revival of the old one.
            f.controller.signIn("synthetic-same-owner", "synthetic")
            val reopenedAccount = f.account()
            assertEquals(account.root, reopenedAccount.root)
            assertNotEquals(account.identity.generation, reopenedAccount.identity.generation)
            assertEquals(aux, WhoopDatabase.get(reopenedAccount).whoopDao().v18AuxIdentity(f.device, 100, 4294967295L))
        }
    }

    @Test fun ledgerMismatchRollsBackAndValidLedgerIsNeverRewrittenOrInherited() {
        oldDb().use { helper ->
            val db = helper.writableDatabase; val fields = V18AuxIdentity.pack(V18AuxRow(100, recordIndex = 0))
            db.execSQL("INSERT INTO v18AuxSample(rowid,deviceId,ts,fields) VALUES(77,'fixture',100,?)", arrayOf(fields))
            db.execSQL("CREATE TABLE ingestRawResource(lane TEXT,deviceId TEXT,resourceKey TEXT,contentSHA256 TEXT,byteCount INTEGER)")
            db.execSQL("INSERT INTO ingestRawResource VALUES('v18AuxSample','fixture','100','mismatch',?)", arrayOf(fields.size))
            db.execSQL("CREATE TABLE rawDurabilityReceipt(resourceKey TEXT,receiptId TEXT)")
            db.execSQL("INSERT INTO rawDurabilityReceipt VALUES('100','old-receipt')")
            assertTrue(runCatching { migrate(db) }.isFailure)
            db.query("SELECT rowid,fields FROM v18AuxSample").use {
                assertTrue(it.moveToFirst()); assertEquals(77, it.getLong(0)); assertArrayEquals(fields, it.getBlob(1))
            }
            db.execSQL("UPDATE ingestRawResource SET contentSHA256=?", arrayOf(V18AuxIdentityMigration.sha256(fields)))
            migrate(db)
            db.execSQL("INSERT INTO v18AuxSample(deviceId,ts,recordIndex,fields,resourceKey) VALUES('fixture',100,1,?,'100:1')",
                arrayOf(V18AuxIdentity.pack(V18AuxRow(100, recordIndex = 1))))
            db.query("SELECT COUNT(*) FROM v18AuxSample a JOIN rawDurabilityReceipt r ON r.resourceKey=a.resourceKey").use {
                assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0))
            }
            db.query("SELECT resourceKey,receiptId FROM rawDurabilityReceipt").use {
                assertTrue(it.moveToFirst()); assertEquals("100", it.getString(0)); assertEquals("old-receipt", it.getString(1)); assertFalse(it.moveToNext())
            }
        }
    }

    @Test fun actualRepositoryPreservesSiblingsDuplicateKeyAndDurablyQuarantinesConflict() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val db = WhoopDatabase.get(account); val repo = WhoopRepository(db)
            val ts = 1700000000L
            val zero = V18AuxRow(ts, recordIndex = 0, rrCount = 1)
            val max = V18AuxRow(ts, recordIndex = 4294967295L, rrCount = 2)
            val unknown = V18AuxRow(ts, rrCount = 3)
            repo.insert(StreamBatch(v18Aux = listOf(zero, max, unknown)), f.device, v18AuxRetentionRows = 1, v18AuxPruneEveryRows = 1)
            repo.insert(StreamBatch(v18Aux = listOf(zero)), f.device)
            val rows = db.whoopDao().v18AuxSamples(f.device, ts, ts, 10)
            assertEquals(listOf(-1L, 0L, 4294967295L), rows.map { it.recordIndex })
            assertEquals(listOf("$ts:-1", "$ts:0", "$ts:4294967295"), rows.map { it.resourceKey })
            val failure = runCatching { repo.insert(StreamBatch(v18Aux = listOf(zero.copy(rrCount = 99))), f.device) }.exceptionOrNull()
            assertTrue("Expected explicit conflict after durable archive, got $failure", failure is V18AuxIdentityConflict)
            val saved = db.whoopDao().v18AuxIdentity(f.device, ts, 0)!!
            assertArrayEquals(V18AuxIdentity.pack(zero), saved.fields)
            val files = java.io.File(account.root, "quarantine/v18-conflicts").listFiles()!!.filter { it.extension == "json" }
            assertEquals(1, files.size)
            val archive = JSONObject(files.single().readText())
            assertEquals(f.owner.userID, archive.getString("userID"))
            assertArrayEquals(V18AuxIdentity.pack(zero.copy(rrCount = 99)), android.util.Base64.decode(archive.getString("incomingFields"), android.util.Base64.NO_WRAP))
            assertEquals(3, db.whoopDao().v18AuxSamples(f.device, ts, ts, 10).size)
        }
    }

    @Test fun oldCompatibilityKeySurvivesExactDuplicateAndSiblingHasDifferentKey() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val db = WhoopDatabase.get(f.account()); val row = V18AuxRow(100, recordIndex = 0)
            db.whoopDao().insertV18Aux(listOf(V18AuxSampleEntity(f.device, 100, 0, V18AuxIdentity.pack(row), "100")))
            val repo = WhoopRepository(db)
            repo.insert(StreamBatch(v18Aux = listOf(row, row.copy(recordIndex = 1))), f.device)
            assertEquals("100", db.whoopDao().v18AuxIdentity(f.device, 100, 0)!!.resourceKey)
            assertEquals("100:1", db.whoopDao().v18AuxIdentity(f.device, 100, 1)!!.resourceKey)
        }
    }

    @Test fun unavailableConflictArchiveRollsBackChunkWithoutReplacingOriginal() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val db = WhoopDatabase.get(account); val repo = WhoopRepository(db)
            val original = V18AuxRow(100, recordIndex = 0, rrCount = 1)
            repo.insert(StreamBatch(v18Aux = listOf(original)), f.device)
            val blocked = java.io.File(account.root, "quarantine/v18-conflicts")
            check(blocked.parentFile!!.isDirectory || blocked.parentFile!!.mkdirs())
            blocked.writeText("synthetic file blocks archive directory creation")
            val failure = runCatching { repo.insert(StreamBatch(steps = listOf(StepRow(100, 1, null)),
                v18Aux = listOf(original.copy(rrCount = 99))), f.device) }.exceptionOrNull()
            assertNotNull(failure); assertFalse(failure is V18AuxIdentityConflict)
            assertArrayEquals(V18AuxIdentity.pack(original), db.whoopDao().v18AuxIdentity(f.device, 100, 0)!!.fields)
            assertTrue(db.whoopDao().stepSamples(f.device, 0, 200, 10).isEmpty())
            assertEquals("synthetic file blocks archive directory creation", blocked.readText())
        }
    }

    @Test fun scalarMigrationIsNullableAndProvenanceAndDebtRollbackWithTheScalar() = runBlocking(Dispatchers.IO) {
        oldDb().use { helper ->
            val db = helper.writableDatabase
            for (table in listOf("stepSample", "sleepStateSample", "ppgHrSample")) {
                db.execSQL("CREATE TABLE $table(ts INTEGER PRIMARY KEY)"); db.execSQL("INSERT INTO $table VALUES(1)")
            }
            db.beginTransaction()
            try { WhoopDatabase.MIGRATION_41_42.migrate(db); db.setTransactionSuccessful() } finally { db.endTransaction() }
            for (table in listOf("stepSample", "sleepStateSample", "ppgHrSample")) db.query("SELECT provenanceJSON FROM $table").use {
                assertTrue(it.moveToFirst()); assertTrue(it.isNull(0))
            }
        }
        W4NativeFixture().use { f ->
            val db = WhoopDatabase.get(f.account()); val repo = WhoopRepository(db)
            val provenance = ScalarProvenance.v18(byteArrayOf(1, 2, 3), 0)
            db.openHelper.writableDatabase.execSQL("""CREATE TRIGGER reject_debt BEFORE INSERT ON syncJob
                BEGIN SELECT RAISE(ABORT,'synthetic debt failure'); END""")
            assertTrue(runCatching { repo.insert(StreamBatch(steps = listOf(StepRow(100, 65535, 2, provenance))), f.device,
                markPostBackfillDebt = true) }.isFailure)
            assertTrue(db.whoopDao().stepSamples(f.device, 0, 200, 10).isEmpty())
            db.openHelper.writableDatabase.execSQL("DROP TRIGGER reject_debt")
            repo.insert(StreamBatch(steps = listOf(StepRow(100, 65535, 2, provenance), StepRow(101, 0, null, null))), f.device,
                markPostBackfillDebt = true)
            val samples = db.whoopDao().stepSamples(f.device, 0, 200, 10)
            assertEquals(listOf(65535, 0), samples.map { it.counter })
            assertEquals(provenance, samples.first().provenanceJSON); assertNull(samples.last().provenanceJSON)
        }
    }
}
