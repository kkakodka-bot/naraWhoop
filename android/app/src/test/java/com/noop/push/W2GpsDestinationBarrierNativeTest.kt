package com.noop.push

import android.app.Application
import android.database.Cursor
import android.database.MatrixCursor
import android.database.sqlite.SQLiteDatabase
import androidx.sqlite.db.SupportSQLiteDatabase
import com.noop.data.DataBackup
import com.noop.data.GpsDestinationDirectorySync
import com.noop.data.GpsDestinationDurabilityBarrier
import com.noop.data.NativeGpsDestinationDirectorySync
import com.noop.data.WhoopDatabase
import com.noop.data.WhoopRepository
import com.noop.location.AccountGpsSession
import com.noop.location.GpsWorkoutFinalizer
import com.noop.location.GpsWorkoutPayload
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode
import org.robolectric.nativeruntime.SQLiteConnectionNatives

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 34], application = Application::class)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class W2GpsDestinationBarrierNativeTest {
    private fun phase(db: WhoopDatabase): Int? = db.openHelper.readableDatabase
        .query("SELECT phase FROM gpsDestinationBarrier WHERE singleton=1").use { if (it.moveToFirst()) it.getInt(0) else null }

    private fun checkpointFault(result: () -> Cursor): (SupportSQLiteDatabase) -> SupportSQLiteDatabase = { sql ->
        object : SupportSQLiteDatabase by sql {
            override fun query(query: String): Cursor {
                assertEquals("PRAGMA main.wal_checkpoint(FULL)", query)
                assertFalse(sql.inTransaction())
                return result()
            }
        }
    }

    private suspend fun assertRetained(f: GpsDeliveryFixture, id: String, payload: GpsWorkoutPayload) {
        assertEquals(id, f.route()!!.id); assertEquals(2, f.route()!!.pointCount)
        assertArrayEquals(payload.encode(), f.payload(id).encode())
        assertArrayEquals(payload.encode(), f.blob(payload, "payload"))
        assertEquals(payload.samples, f.canonical(payload))
    }

    @Test fun restoredWalCopyNeedsRealCommittedControlAndCheckedNativeCheckpointBeforeDelete() = runBlocking(Dispatchers.IO) {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id); val witness = f.blob(payload, "witness")
            val original = f.db
            assertEquals(DataBackup.ImportResult.NeedsRestart,
                DataBackup.installStagedBackup(f.account, f.stagedWal(), f.storage.emptySettings(f.account)))
            assertNotSame(original, f.db)
            val stages = mutableListOf<GpsDestinationDurabilityBarrier.Step>()
            val synced = mutableListOf<File>()
            var checkpoints = 0
            val barrier = GpsDestinationDurabilityBarrier(checkpointView = { sql ->
                object : SupportSQLiteDatabase by sql {
                    override fun query(query: String): Cursor {
                        assertFalse(sql.inTransaction()); assertEquals(0, phase(f.db))
                        assertEquals(GpsDestinationDurabilityBarrier.Step.CONTROL_COMMITTED, stages.last())
                        checkpoints++
                        return sql.query(query).also {
                            assertTrue(it.moveToFirst()); assertEquals(0, it.getInt(0))
                            assertTrue(it.getLong(1) > 0); assertEquals(it.getLong(1), it.getLong(2))
                            it.moveToPosition(-1)
                        }
                    }
                }
            }, directories = GpsDestinationDirectorySync { path ->
                assertEquals(GpsDestinationDurabilityBarrier.Step.CHECKPOINT_COMPLETED, stages.last())
                NativeGpsDestinationDirectorySync.sync(path); synced += path
            }, afterStep = { stages += it })
            GpsWorkoutFinalizer(f.account, f.gps, destinationBarrier = barrier, beforeGpsDelete = {
                assertEquals(GpsDestinationDurabilityBarrier.Step.values().toList(), stages)
                assertTrue(f.db.openHelper.writableDatabase.inTransaction())
                assertEquals(id, f.route()!!.id); assertEquals(5, synced.size)
            }, onCommitted = { assertEquals(0, it.insertedHr) }).finish(id, f.changed)
            assertEquals(1, checkpoints); assertNull(f.route())
            assertArrayEquals(witness, f.blob(payload, "witness"))
            assertEquals(checkNotNull(f.account.getDatabasePath(WhoopDatabase.DB_NAME).parentFile).canonicalFile, synced.first())
            assertEquals(synced.first().parentFile, synced[1])
            assertTrue(synced.all { it.isDirectory })
        }
    }

    @Test fun nativeControlMutationFailureRollsBackAndNeverCallsCheckpointOrDelete() = runBlocking(Dispatchers.IO) {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id)
            f.db.openHelper.writableDatabase.execSQL("CREATE TRIGGER gps_barrier_fault BEFORE INSERT ON gpsDestinationBarrier BEGIN SELECT RAISE(ABORT,'synthetic'); END")
            gpsRejects { GpsWorkoutFinalizer(f.account, f.gps,
                destinationBarrier = GpsDestinationDurabilityBarrier(checkpointView = { fail("failed control must not checkpoint"); it }),
                beforeGpsDelete = { fail("failed control must not delete") }).finish(id, f.changed) }
            assertNull(phase(f.db)); assertRetained(f, id, payload)
            f.db.openHelper.writableDatabase.execSQL("DROP TRIGGER gps_barrier_fault")
            gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, destinationBarrier = GpsDestinationDurabilityBarrier(afterStep = {
                if (it == GpsDestinationDurabilityBarrier.Step.CONTROL_MUTATED) throw IOException("precommit interruption")
            })).finish(id, f.changed) }
            assertNull(phase(f.db)); assertRetained(f, id, payload)
        }
    }

    @Test fun busyEmptyIncompleteMalformedAndThrowingCheckpointAllRetainExactDebt() = runBlocking(Dispatchers.IO) {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id)
            val cases: List<() -> Cursor> = listOf(
                { MatrixCursor(arrayOf("busy", "log", "checkpointed")).apply { addRow(arrayOf(1, 2, 1)) } },
                { MatrixCursor(arrayOf("busy", "log", "checkpointed")).apply { addRow(arrayOf(0, 0, 0)) } },
                { MatrixCursor(arrayOf("busy", "log", "checkpointed")).apply { addRow(arrayOf(0, -1, -1)) } },
                { MatrixCursor(arrayOf("busy", "log", "checkpointed")).apply { addRow(arrayOf(0, 2, 1)) } },
                { MatrixCursor(arrayOf("busy", "log", "checkpointed")).apply { addRow(arrayOf("0", 1, 1)) } },
                { MatrixCursor(arrayOf("busy", "log", "checkpointed")) },
                { MatrixCursor(arrayOf("busy", "log", "checkpointed")).apply { repeat(2) { addRow(arrayOf(0, 1, 1)) } } },
                { throw IOException("synthetic checkpoint IO error") },
            )
            var previous: Int? = null
            for (result in cases) {
                gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, destinationBarrier = GpsDestinationDurabilityBarrier(
                    checkpointView = checkpointFault(result), directories = GpsDestinationDirectorySync { fail("failed checkpoint must not sync directories") }),
                    beforeGpsDelete = { fail("failed checkpoint must not delete") }).finish(id, f.changed) }
                assertEquals(previous?.let { 1 - it } ?: 0, phase(f.db))
                previous = phase(f.db); assertRetained(f, id, payload)
            }
            GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed)
            assertNull(f.route())
        }
    }

    @Test fun realNativeReaderPreventsFullCheckpointThenReleasedReaderAllowsFreshBarrier() = runBlocking(Dispatchers.IO) {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id)
            // A separate SQLite connection holds a real deferred read snapshot. A materialized
            // Android cursor alone would release its connection and would not exercise SQLITE_BUSY.
            val reader = SQLiteConnectionNatives.nativeOpen(f.account.getDatabasePath(WhoopDatabase.DB_NAME).path,
                SQLiteDatabase.OPEN_READONLY, "gps-barrier-reader", false, false, 0, 0)
            fun execute(query: String, read: Boolean = false) {
                val statement = SQLiteConnectionNatives.nativePrepareStatement(reader, query)
                try {
                    if (read) assertTrue(SQLiteConnectionNatives.nativeExecuteForLong(reader, statement) > 0)
                    else SQLiteConnectionNatives.nativeExecute(reader, statement, false)
                } finally { SQLiteConnectionNatives.nativeFinalizeStatement(reader, statement) }
            }
            var observedBusy = false
            try {
                execute("BEGIN DEFERRED")
                execute("SELECT count(*) FROM gpsWorkoutDelivery", read = true)
                gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, destinationBarrier = GpsDestinationDurabilityBarrier(
                    checkpointView = { sql -> object : SupportSQLiteDatabase by sql {
                        override fun query(query: String): Cursor = sql.query(query).also {
                            assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0))
                            assertTrue(it.getLong(1) > it.getLong(2)); observedBusy = true
                            it.moveToPosition(-1)
                        }
                    } }, directories = GpsDestinationDirectorySync { fail("busy checkpoint cannot retire GPS") }
                )).finish(id, f.changed) }
                assertTrue(observedBusy); assertEquals(0, phase(f.db)); assertRetained(f, id, payload)
            } finally {
                try { execute("ROLLBACK") } finally { SQLiteConnectionNatives.nativeClose(reader) }
            }
            GpsWorkoutFinalizer(f.account, f.gps, onCommitted = { assertEquals(0, it.insertedHr) }).finish(id, f.changed)
            assertEquals(1, phase(f.db)); assertNull(f.route())
        }
    }

    @Test fun failedControlUpdateLeavesCommittedBitAndExactDebtUnchanged() = runBlocking(Dispatchers.IO) {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id)
            gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, destinationBarrier = GpsDestinationDurabilityBarrier(
                afterStep = { if (it == GpsDestinationDurabilityBarrier.Step.CONTROL_COMMITTED) throw IOException("stop") }
            )).finish(id, f.changed) }
            assertEquals(0, phase(f.db))
            f.db.openHelper.writableDatabase.execSQL("CREATE TRIGGER gps_barrier_update_fault BEFORE UPDATE ON gpsDestinationBarrier BEGIN SELECT RAISE(ABORT,'synthetic'); END")
            gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, destinationBarrier = GpsDestinationDurabilityBarrier(
                checkpointView = { fail("rolled back update must not checkpoint"); it })).finish(id, f.changed) }
            assertEquals(0, phase(f.db)); assertRetained(f, id, payload)
            f.db.openHelper.writableDatabase.execSQL("DROP TRIGGER gps_barrier_update_fault")
            GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed)
            assertEquals(1, phase(f.db)); assertNull(f.route())
        }
    }

    @Test fun retirementBeforeNativeControlCommitRollsBackAndRetainsGps() = runBlocking(Dispatchers.IO) {
        retirementAt(GpsDestinationDurabilityBarrier.Step.CONTROL_MUTATED)
    }

    @Test fun retirementAfterControlCommitRequiresFreshSuccessorBarrier() = runBlocking(Dispatchers.IO) {
        retirementAt(GpsDestinationDurabilityBarrier.Step.CONTROL_COMMITTED)
    }

    @Test fun retirementAfterCheckpointRequiresFreshSuccessorBarrier() = runBlocking(Dispatchers.IO) {
        retirementAt(GpsDestinationDurabilityBarrier.Step.CHECKPOINT_COMPLETED)
    }

    @Test fun retirementAfterDirectorySyncRequiresFreshSuccessorBarrier() = runBlocking(Dispatchers.IO) {
        retirementAt(GpsDestinationDurabilityBarrier.Step.DIRECTORIES_SYNCED)
    }

    private suspend fun retirementAt(point: GpsDestinationDurabilityBarrier.Step) {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id)
            val oldDb = f.db
            gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, destinationBarrier = GpsDestinationDurabilityBarrier(
                afterStep = { if (it == point) f.storage.login("a") }
            ), beforeGpsDelete = { fail("retired generation cannot delete GPS") }).finish(id, f.changed) }
            // Inspect the rolled-back control before replacing the retired DB handle.
            val previous = phase(oldDb)
            assertEquals(if (point == GpsDestinationDurabilityBarrier.Step.CONTROL_MUTATED) null else 0, previous)
            f.reopenRoom()
            assertRetained(f, id, payload)
            val successor = AccountGpsSession(f.account)
            try {
                successor.recoverDurable()
                GpsWorkoutFinalizer(f.account, successor, onCommitted = { assertEquals(0, it.insertedHr) }).finish(id, f.changed)
                assertEquals(previous?.let { 1 - it } ?: 0, phase(f.db)); assertNull(f.route())
            } finally { successor.retireAndJoin() }
        }
    }

    @Test fun failedDirectoryBarrierStillFailsAfterColdReopenThenFreshRetrySucceedsWithoutNewHr() = runBlocking(Dispatchers.IO) {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id); val bytes = f.blob(payload, "witness")
            assertEquals(DataBackup.ImportResult.NeedsRestart,
                DataBackup.installStagedBackup(f.account, f.stagedWal(), f.storage.emptySettings(f.account)))
            var attempts = 0
            val barrier = GpsDestinationDurabilityBarrier(directories = GpsDestinationDirectorySync {
                attempts++; throw IOException("synthetic directory barrier failure")
            })
            gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, destinationBarrier = barrier).finish(id, f.changed) }
            assertEquals(1, attempts); assertEquals(0, phase(f.db)); assertRetained(f, id, payload)
            f.reopenRoom()
            val successor = AccountGpsSession(f.account)
            try {
                successor.recoverDurable()
                gpsRejects { GpsWorkoutFinalizer(f.account, successor, destinationBarrier = barrier,
                    onCommitted = { assertEquals(0, it.insertedHr) }).finish(id, f.changed) }
                assertEquals(2, attempts); assertEquals(1, phase(f.db)); assertRetained(f, id, payload)
                val repository = WhoopRepository(f.db)
                GpsWorkoutFinalizer(f.account, successor, onCommitted = {
                    assertEquals(0, it.insertedHr); assertFalse(repository.publishGpsHrCommit(it) { true })
                }).finish(id, f.changed)
                assertEquals(0, phase(f.db)); assertNull(f.route()); assertEquals(0L, repository.sleepSampleRevision.value)
                assertArrayEquals(bytes, f.blob(payload, "witness"))
            } finally { successor.retireAndJoin() }
        }
    }

    @Test fun postcommitAndPostcheckpointInterruptionsRequireFreshControlMutationOnRetry() = runBlocking(Dispatchers.IO) {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id); var previous: Int? = null
            for (point in listOf(GpsDestinationDurabilityBarrier.Step.CONTROL_COMMITTED,
                GpsDestinationDurabilityBarrier.Step.CHECKPOINT_COMPLETED, GpsDestinationDurabilityBarrier.Step.DIRECTORIES_SYNCED)) {
                gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, destinationBarrier = GpsDestinationDurabilityBarrier(afterStep = {
                    if (it == point) throw IOException("synthetic interruption at $point")
                })).finish(id, f.changed) }
                assertEquals(previous?.let { 1 - it } ?: 0, phase(f.db)); previous = phase(f.db)
                assertRetained(f, id, payload)
            }
            GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed)
            assertEquals(1 - checkNotNull(previous), phase(f.db)); assertNull(f.route())
        }
    }

    @Test fun ordinaryWriterAfterCompletedBarrierIsCaughtByReacquiredExactProof() = runBlocking(Dispatchers.IO) {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id)
            gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, destinationBarrier = GpsDestinationDurabilityBarrier(afterStep = {
                if (it == GpsDestinationDurabilityBarrier.Step.DIRECTORIES_SYNCED) {
                    f.db.openHelper.writableDatabase.execSQL("UPDATE workout SET notes='concurrent edit'")
                }
            }), beforeGpsDelete = { fail("changed exact proof must not delete") }).finish(id, f.changed) }
            assertRetained(f, id, payload)
        }
    }

    @Test fun restoreCannotEnterBetweenControlCommitCheckpointAndFinalProof() = runBlocking(Dispatchers.IO) {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id); val backup = f.stagedWal()
            val reached = CountDownLatch(1); val release = CountDownLatch(1); val restored = CountDownLatch(1)
            val executor = Executors.newFixedThreadPool(2)
            try {
                val finish = executor.submit {
                    runBlocking { GpsWorkoutFinalizer(f.account, f.gps, destinationBarrier = GpsDestinationDurabilityBarrier(afterStep = {
                        if (it == GpsDestinationDurabilityBarrier.Step.CONTROL_COMMITTED) {
                            reached.countDown(); check(release.await(10, TimeUnit.SECONDS))
                        }
                    })).finish(id, f.changed) }
                }
                assertTrue(reached.await(10, TimeUnit.SECONDS))
                val restore = executor.submit<DataBackup.ImportResult> {
                    DataBackup.installStagedBackup(f.account, backup, f.storage.emptySettings(f.account)).also { restored.countDown() }
                }
                assertFalse(restored.await(150, TimeUnit.MILLISECONDS))
                release.countDown(); finish.get(10, TimeUnit.SECONDS)
                assertEquals(DataBackup.ImportResult.NeedsRestart, restore.get(10, TimeUnit.SECONDS))
                assertNull(f.route()); assertArrayEquals(payload.encode(), f.blob(payload, "payload"))
            } finally { release.countDown(); executor.shutdownNow(); assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS)) }
        }
    }

    @Test fun malformedOrOverCapacityControlRowsFailClosedWithoutRepairingThem() = runBlocking(Dispatchers.IO) {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id)
            for (insert in listOf("INSERT INTO gpsDestinationBarrier VALUES(1,2)",
                "INSERT INTO gpsDestinationBarrier VALUES(2,0)", "INSERT INTO gpsDestinationBarrier VALUES(1,'invalid')",
                "INSERT INTO gpsDestinationBarrier VALUES(1,0),(2,1)")) {
                val sql = f.db.openHelper.writableDatabase
                sql.execSQL("DELETE FROM gpsDestinationBarrier"); sql.execSQL(insert)
                gpsRejects { GpsWorkoutFinalizer(f.account, f.gps, destinationBarrier = GpsDestinationDurabilityBarrier(
                    checkpointView = { fail("malformed metadata must not checkpoint"); it })).finish(id, f.changed) }
                assertRetained(f, id, payload)
            }
        }
    }

    @Test fun nativeDirectoryBarrierRejectsFileSymlinkAndMissingPathWithoutChangingBytes() {
        val root = Files.createTempDirectory("gps-directory-barrier-")
        val data = root.resolve("untouched.sqlite")
        val bytes = byteArrayOf(1, 2, 3); Files.write(data, bytes)
        val link = root.resolve("symlink"); Files.createSymbolicLink(link, root)
        for (path in listOf(data, link, root.resolve("absent"))) {
            try { NativeGpsDestinationDirectorySync.sync(path.toFile()); fail("must reject non-directory or symlink") }
            catch (_: Exception) { }
        }
        NativeGpsDestinationDirectorySync.sync(root.toFile())
        assertArrayEquals(bytes, Files.readAllBytes(data))
    }
}
