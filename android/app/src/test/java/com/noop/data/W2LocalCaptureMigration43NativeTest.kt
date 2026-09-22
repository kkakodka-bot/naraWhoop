package com.noop.data

import android.app.Application
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import androidx.sqlite.db.SupportSQLiteDatabase
import com.noop.account.AccountCaptureJournal
import com.noop.account.AccountStorageContext
import com.noop.account.AccountStorageMutationLease
import com.noop.account.AccountWriteRevokedException
import com.noop.account.CaptureAdmission
import com.noop.account.CaptureBatch
import com.noop.account.CaptureFormat
import com.noop.account.CaptureNamespace
import com.noop.account.CaptureNamespaceAccess
import com.noop.account.CaptureOwner
import com.noop.account.CaptureRecord
import com.noop.account.CaptureRetirement
import com.noop.account.CaptureRoute
import com.noop.account.DurableCapture
import com.noop.push.AccountScope
import com.noop.push.W4NativeFixture
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class W2LocalCaptureMigration43NativeTest {
    @Test fun actual42Through43To44PreservesTypedRowsOwnerBlobsRowidsAndCaptureIndexAcrossReopen() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            val before = createPriorSchema(account.getDatabasePath(WhoopDatabase.DB_NAME), f.owner)
            val room = WhoopDatabase.get(account)
            val db = room.openHelper.writableDatabase // Real registered migration and generated Room validation.
            assertEquals(44, db.version); assertEquals(before, snapshot(db::query)); assertEmptyIndex(db)
            val owner = CaptureOwner(f.owner, SOURCE)
            val store = store(owner, room)
            val captured = withJournal(account, room, owner) { journal ->
                capture(journal).also { assertEquals(CaptureRegistration(true, 4), store.register(it)) }
            }
            val originalFile = captureFile(account, captured); val digest = digest(originalFile)
            val pending = store.pendingMembers()
            assertEquals(captured.members, pending.map { it.member })
            WhoopDatabase.close()
            assertTrue(runCatching { WhoopDatabase.get(account) }.exceptionOrNull() is AccountWriteRevokedException)
            f.controller.signIn("synthetic-same-owner", "synthetic")
            val next = f.account()
            assertEquals(account.root, next.root); assertNotEquals(account.identity.generation, next.identity.generation)
            val reopened = WhoopDatabase.get(next)
            assertEquals(44, reopened.openHelper.readableDatabase.version)
            assertEquals(before, snapshot(reopened.openHelper.readableDatabase::query))
            val nextStore = store(owner, reopened)
            withJournal(next, reopened, owner) { journal ->
                val recovered = journal.recoverPage().single()
                assertEquals(captured.resource, recovered.resource); assertEquals(captured.members, recovered.members)
                assertEquals(account.identity.generation.toString(), recovered.resource.generation)
                assertArrayEquals(captured.payload(1), recovered.payload(1))
                assertEquals(CaptureRegistration(false, 0), nextStore.register(recovered))
            }
            assertEquals(pending, nextStore.pendingMembers()); assertEquals(digest, digest(originalFile))
            reopened.openHelper.readableDatabase.query("PRAGMA foreign_key_check").use { assertFalse(it.moveToFirst()) }
        }
    }

    @Test fun actualOlder42RestoreKeepsSealedFilesAndReindexesOnlyUnderFreshAdmittedWriter() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val room = WhoopDatabase.get(account)
            assertEquals(44, room.openHelper.writableDatabase.version)
            val owner = CaptureOwner(f.owner, SOURCE); val oldStore = store(owner, room)
            val captured = withJournal(account, room, owner) { journal ->
                capture(journal).also { oldStore.register(it) }
            }
            val originalFile = captureFile(account, captured); val bytes = originalFile.readBytes()
            val backup = File(account.cacheDir, "synthetic-prior42-${UUID.randomUUID()}.sqlite")
            val restoredRows = createPriorSchema(backup, f.owner)
            // Includes real staging, origin/owner validation, namespace lease, transaction drain and install.
            assertEquals(DataBackup.ImportResult.NeedsRestart, DataBackup.importFrom(account, Uri.fromFile(backup)))
            assertFalse(room.isOpen); assertArrayEquals(bytes, originalFile.readBytes())
            assertTrue(runCatching { oldStore.register(captured) }.exceptionOrNull() is AccountWriteRevokedException)
            SQLiteDatabase.openDatabase(account.getDatabasePath(WhoopDatabase.DB_NAME).path, null, SQLiteDatabase.OPEN_READONLY).use { sql ->
                assertEquals(42, sql.version); assertEquals(restoredRows, snapshot({ sql.rawQuery(it, null) }))
                sql.rawQuery("SELECT name FROM sqlite_master WHERE name IN ('localCaptureResource','localCaptureMember')", null).use {
                    assertFalse(it.moveToFirst())
                }
            }
            f.controller.signIn("synthetic-same-owner", "synthetic")
            val next = f.account(); val migrated = WhoopDatabase.get(next)
            assertEquals(account.root, next.root); assertNotEquals(account.identity.generation, next.identity.generation)
            val db = migrated.openHelper.writableDatabase
            assertEquals(44, db.version); assertEquals(restoredRows, snapshot(db::query)); assertEmptyIndex(db)
            val nextStore = store(owner, migrated)
            withJournal(next, migrated, owner) { journal ->
                val recovered = journal.recoverPage().single()
                assertEquals(captured.resource, recovered.resource); assertEquals(captured.members, recovered.members)
                assertEquals(CaptureRegistration(true, 4), nextStore.register(recovered))
                assertEquals(CaptureRegistration(false, 0), nextStore.register(recovered))
            }
            assertEquals(captured.members, nextStore.pendingMembers().map { it.member })
            assertArrayEquals(bytes, originalFile.readBytes()); assertEquals(1, originalFile.parentFile!!.listFiles()!!.size)
            WhoopDatabase.close(); f.controller.signIn("synthetic-same-owner", "synthetic")
            val reopened = WhoopDatabase.get(f.account())
            assertEquals(restoredRows, snapshot(reopened.openHelper.readableDatabase::query))
            assertEquals(captured.members, store(owner, reopened).pendingMembers().map { it.member })
        }
    }

    @Test fun foreignOwner42RestoreCannotReplaceCurrentIndexOrCaptureFile() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val room = WhoopDatabase.get(account)
            assertEquals(44, room.openHelper.writableDatabase.version)
            val owner = CaptureOwner(f.owner, SOURCE); val store = store(owner, room)
            val captured = withJournal(account, room, owner) { journal -> capture(journal).also { store.register(it) } }
            val pending = store.pendingMembers(); val bytes = captureFile(account, captured).readBytes()
            val before = snapshot(room.openHelper.readableDatabase::query)
            val backup = File(account.cacheDir, "synthetic-foreign42-${UUID.randomUUID()}.sqlite")
            createPriorSchema(backup, AccountScope.create(f.owner.projectURL, UUID.randomUUID().toString()))
            assertTrue(DataBackup.importFrom(account, Uri.fromFile(backup)) is DataBackup.ImportResult.Failed)
            assertTrue(room.isOpen); assertEquals(44, room.openHelper.readableDatabase.version)
            assertEquals(before, snapshot(room.openHelper.readableDatabase::query))
            assertEquals(pending, store.pendingMembers()); assertArrayEquals(bytes, captureFile(account, captured).readBytes())
        }
    }

    @Test fun actual43To44AddsOnlyEmptyControlTableAndPreservesGpsAndPopulatedCaptureIndexAcrossReopen() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            val before = createPriorSchema(account.getDatabasePath(WhoopDatabase.DB_NAME), f.owner, version = 43)
            assertEquals(1, before.getValue("localCaptureResource").size)
            assertEquals(2, before.getValue("localCaptureMember").size)
            val room = WhoopDatabase.get(account)
            val db = room.openHelper.writableDatabase
            assertEquals(44, db.version)
            assertEquals(before, snapshot(db::query, includeRoom43 = true))
            db.query("SELECT projectionState,bucket FROM localCaptureMember ORDER BY recordOrdinal").use {
                assertTrue(it.moveToFirst()); assertEquals(0, it.getInt(0)); assertTrue(it.isNull(1))
                assertTrue(it.moveToNext()); assertEquals(1, it.getInt(0)); assertEquals(17L, it.getLong(1))
                assertFalse(it.moveToNext())
            }
            db.query("PRAGMA foreign_key_check").use { assertFalse(it.moveToFirst()) }
            db.query("SELECT singleton,phase FROM gpsDestinationBarrier").use { assertFalse(it.moveToFirst()) }
            db.query("PRAGMA table_info(gpsDestinationBarrier)").use { columns ->
                assertTrue(columns.moveToFirst()); assertEquals("singleton", columns.getString(1))
                assertEquals("INTEGER", columns.getString(2)); assertEquals(1, columns.getInt(3))
                assertTrue(columns.isNull(4)); assertEquals(1, columns.getInt(5))
                assertTrue(columns.moveToNext()); assertEquals("phase", columns.getString(1))
                assertEquals("INTEGER", columns.getString(2)); assertEquals(1, columns.getInt(3))
                assertTrue(columns.isNull(4)); assertEquals(0, columns.getInt(5)); assertFalse(columns.moveToNext())
            }
            WhoopDatabase.close(); f.controller.signIn("synthetic-same-owner", "synthetic")
            val reopened = WhoopDatabase.get(f.account()).openHelper.readableDatabase
            assertEquals(44, reopened.version)
            assertEquals(before, snapshot(reopened::query, includeRoom43 = true))
            reopened.query("PRAGMA foreign_key_check").use { assertFalse(it.moveToFirst()) }
            reopened.query("SELECT count(*) FROM gpsDestinationBarrier").use {
                assertTrue(it.moveToFirst()); assertEquals(0, it.getInt(0))
            }
        }
    }

    /** Construct the historical shape from the CURRENT export, never a stale retained JSON. */
    private fun createPriorSchema(file: File, scope: AccountScope, version: Int = 42): Map<String, List<List<String>>> {
        require(version in 42..43)
        assertEquals("This gate requires root's generated Room44 implementation", 44, WhoopDatabase.SCHEMA_VERSION)
        val directory = checkNotNull(System.getProperty("room.schemaLocation")) { "Run root's Room schema snapshot task" }
        val export = File(directory, "com.noop.data.WhoopDatabase/${WhoopDatabase.SCHEMA_VERSION}.json")
        assertTrue("Current Room export missing: $export", export.isFile)
        val schema = JSONObject(export.readText()).getJSONObject("database")
        assertEquals(44, schema.getInt("version"))
        val entities = schema.getJSONArray("entities")
        val names = (0 until entities.length()).map { entities.getJSONObject(it).getString("tableName") }
        assertTrue(names.containsAll(POST42_ADDITIONS)); assertEquals(names.size, names.distinct().size)
        check(!file.exists()); check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
        return SQLiteDatabase.openOrCreateDatabase(file, null).use { sql ->
            sql.beginTransaction()
            try {
                for (i in 0 until entities.length()) {
                    val entity = entities.getJSONObject(i); val name = entity.getString("tableName")
                    if (name == "gpsDestinationBarrier" || (version == 42 && name in ROOM43_ADDITIONS)) continue
                    sql.execSQL(entity.getString("createSql").replace("\${TABLE_NAME}", name))
                    val indices = entity.getJSONArray("indices")
                    for (j in 0 until indices.length()) sql.execSQL(indices.getJSONObject(j).getString("createSql").replace("\${TABLE_NAME}", name))
                }
                sql.execSQL("CREATE TABLE localAccountOwner(singleton INTEGER PRIMARY KEY CHECK(singleton=1),projectURL TEXT NOT NULL,userID TEXT NOT NULL)")
                sql.execSQL("INSERT INTO localAccountOwner VALUES(1,?,?)", arrayOf(scope.projectURL, scope.userID))
                // Opaque synthetic old identity: upgrade must replace it after full Room validation.
                // This is origin bookkeeping, not a guessed hash of a deployed/stale 42 export.
                sql.execSQL("CREATE TABLE room_master_table(id INTEGER PRIMARY KEY,identity_hash TEXT)")
                sql.execSQL("INSERT INTO room_master_table VALUES(42,?)", arrayOf("synthetic-prior$version-migration-fixture"))
                sql.execSQL("INSERT INTO hrSample(rowid,deviceId,ts,bpm,synced) VALUES(17,'synthetic-strap',100,61,0)")
                sql.execSQL("INSERT INTO stepSample(rowid,deviceId,ts,counter,activityClass,synced,provenanceJSON) VALUES(23,'synthetic-strap',100,65535,NULL,0,?)",
                    arrayOf("{\"v\":1,\"origin\":\"legacy-unknown\"}"))
                sql.execSQL("INSERT INTO stepSample(rowid,deviceId,ts,counter,activityClass,synced,provenanceJSON) VALUES(24,'synthetic-strap',101,0,2,1,NULL)")
                for ((ordinal, recordIndex) in listOf(-1L, 0L, 4294967295L).withIndex()) {
                    sql.execSQL("INSERT INTO ppgWaveformSample(rowid,deviceId,ts,samples,burstIndex,recordIndex) VALUES(?,'synthetic-strap',100,?,NULL,?)",
                        arrayOf(30L + ordinal, byteArrayOf(ordinal.toByte(), 0, -1, 127), recordIndex))
                    sql.execSQL("INSERT INTO v18AuxSample(rowid,deviceId,ts,recordIndex,fields,resourceKey) VALUES(?,'synthetic-strap',100,?,?,?)",
                        arrayOf(40L + ordinal, recordIndex, byteArrayOf(0, ordinal.toByte(), -1), "100:$recordIndex"))
                }
                sql.execSQL("INSERT INTO syncJob(kind,owedAt,token,attempts,lastNote) VALUES('score',99,?,3,NULL)", arrayOf(SOURCE.toString()))
                sql.execSQL("INSERT INTO syncJournalEntry(id,ts,wakeReason,stagesRun,stagesOwed,durationMs,note) VALUES(77,100,'synthetic','[]','[\"score\"]',12,'preserve')")
                if (version == 43) {
                    sql.execSQL("""INSERT INTO localCaptureResource(rowid,captureId,projectURL,userID,
                        sourceID,generation,deviceID,serverDeviceID,producerID,format,formatVersion,
                        relativePath,fileSha256,fileBytes,payloadBytes,recordCount,memberCount)
                        VALUES(111,'synthetic-capture',?,?,?,?,'synthetic-strap',?,'synthetic-producer',
                        'WHOOP_FRAME_V1',1,'capture/retained.ncap',?,512,7,2,2)""",
                        arrayOf(scope.projectURL, scope.userID, SOURCE.toString(), SOURCE.toString(),
                            DEVICE.toString(), "a".repeat(64)))
                    sql.execSQL("""INSERT INTO localCaptureMember(rowid,captureId,recordOrdinal,routeOrdinal,
                        encounterOrdinal,receivedAtMs,namespace,sessionID,bucket,payloadOffset,
                        payloadBytes,payloadSha256,projectionState)
                        VALUES(112,'synthetic-capture',0,0,9007199254740993,1700000000001,
                        'IMU_BOUNDED','synthetic-session',NULL,0,3,?,0)""", arrayOf("b".repeat(64)))
                    sql.execSQL("""INSERT INTO localCaptureMember(rowid,captureId,recordOrdinal,routeOrdinal,
                        encounterOrdinal,receivedAtMs,namespace,sessionID,bucket,payloadOffset,
                        payloadBytes,payloadSha256,projectionState)
                        VALUES(113,'synthetic-capture',1,0,9007199254740994,1700000000002,
                        'IMU_CONTINUOUS','synthetic-session',17,3,4,?,1)""", arrayOf("c".repeat(64)))
                    // Opaque retained artifact bytes must survive migration even if a later verifier
                    // would reject them. Migration has no authority to re-encode or repair this data.
                    sql.execSQL("""INSERT INTO gpsWorkoutDelivery(rowid,deviceId,startTs,sport,namespace,
                        projectURL,userID,capturedGeneration,sessionId,formatVersion,payload,payloadSha256,
                        witness,witnessSha256,captureCount,witnessCount,retainedBytes)
                        VALUES(123,'synthetic-strap',100,'Running',?,?,?,?,'synthetic-session',1,?,'synthetic-payload',
                        ?,'synthetic-witness',2,2,7)""",
                        arrayOf(scope.namespace, scope.projectURL, scope.userID, SOURCE.toString(),
                            byteArrayOf(0, -1, 42, 127), byteArrayOf(9, 0, -128)))
                }
                sql.version = version; sql.setTransactionSuccessful()
            } finally { sql.endTransaction() }
            snapshot({ sql.rawQuery(it, null) }, includeRoom43 = version == 43)
        }
    }

    /** Type-tagged native values, including rowid and exact BLOB bytes, not count-only preservation. */
    private fun snapshot(query: (String) -> Cursor, includeRoom43: Boolean = false): Map<String, List<List<String>>> =
        (PRESERVED_TABLES + if (includeRoom43) ROOM43_ADDITIONS else emptySet()).associateWith { table ->
        query("SELECT rowid,* FROM `$table` ORDER BY rowid").use { rows ->
            buildList {
                while (rows.moveToNext()) add((0 until rows.columnCount).map { index ->
                    when (rows.getType(index)) {
                        Cursor.FIELD_TYPE_NULL -> "null"
                        Cursor.FIELD_TYPE_INTEGER -> "integer:${rows.getLong(index)}"
                        Cursor.FIELD_TYPE_FLOAT -> "float:${rows.getDouble(index)}"
                        Cursor.FIELD_TYPE_STRING -> "text:${rows.getString(index)}"
                        Cursor.FIELD_TYPE_BLOB -> "blob:" + rows.getBlob(index).joinToString("") { "%02x".format(it) }
                        else -> error("Unexpected SQLite type")
                    }
                })
            }
        }
    }

    private fun assertEmptyIndex(db: SupportSQLiteDatabase) {
        for (table in POST42_ADDITIONS) db.query("SELECT count(*) FROM $table").use { assertTrue(it.moveToFirst()); assertEquals(0L, it.getLong(0)) }
    }
    private fun admission(room: WhoopDatabase) = object : CaptureAdmission {
        override fun <T> withCurrent(block: () -> T): T = checkNotNull(room.accountWriteFence).commit(block)
    }
    private fun store(owner: CaptureOwner, room: WhoopDatabase) = LocalCaptureStore(owner, admission(room), { room.openHelper.writableDatabase })
    private suspend fun <T> withJournal(account: AccountStorageContext, room: WhoopDatabase, owner: CaptureOwner, body: suspend (AccountCaptureJournal) -> T): T {
        val lease = AccountStorageMutationLease.capture(account)
        val pool = CaptureRetirement.open(checkNotNull(account.root.parentFile), object : CaptureNamespaceAccess {
            override fun <R> withLock(scope: AccountScope, block: () -> R): R {
                check(scope == owner.scope)
                return lease.withStorageLock(block) // File serialization only; no retired SQL permission.
            }
        })
        val journal = try { AccountCaptureJournal.open(pool, owner, account.identity.generation, admission(room)) }
        catch (failure: Throwable) { pool.close(); throw failure }
        return try { body(journal) } finally {
            assertTrue(pool.settle(journal.beginRetirement()).await().settled)
            pool.close()
        }
    }
    private suspend fun capture(journal: AccountCaptureJournal): DurableCapture = journal.commit(journal.reserveBatch(CaptureBatch(
        "synthetic-strap", DEVICE, PRODUCER, CaptureFormat.WHOOP_FRAME_V1, List(2) { ordinal ->
            CaptureRecord(ordinal.toLong(), 1_000, byteArrayOf(ordinal.toByte(), 42), listOf(
                CaptureRoute(CaptureNamespace.IMU_BOUNDED, "bounded-session", 0),
                CaptureRoute(CaptureNamespace.IMU_CONTINUOUS, "continuous-session", 0),
            ))
        },
    )))
    private fun captureFile(account: AccountStorageContext, capture: DurableCapture) = File(account.root, capture.resource.relativePath)
    private fun digest(file: File) = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }

    companion object {
        private val ROOM43_ADDITIONS = setOf("localCaptureResource", "localCaptureMember", "gpsWorkoutDelivery")
        private val POST42_ADDITIONS = ROOM43_ADDITIONS + "gpsDestinationBarrier"
        private val PRESERVED_TABLES = listOf("localAccountOwner", "hrSample", "stepSample", "ppgWaveformSample", "v18AuxSample", "syncJob", "syncJournalEntry")
        private val SOURCE = UUID.fromString("30000000-0000-4000-8000-000000000001")
        private val DEVICE = UUID.fromString("20000000-0000-4000-8000-000000000001")
        private val PRODUCER = UUID.fromString("50000000-0000-4000-8000-000000000001")
    }
}
