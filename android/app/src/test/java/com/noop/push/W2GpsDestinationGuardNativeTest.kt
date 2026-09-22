package com.noop.push

import android.app.Application
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import com.noop.data.WhoopRepository
import com.noop.data.requireDurableAccountCommit
import com.noop.location.GpsWorkoutFinalizer
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 34], application = Application::class)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class W2GpsDestinationGuardNativeTest {
    /** Only the finalizer's diagnostic PRAGMA view is injected. Its writes and transaction ownership
     * remain the actual Room writer. Fault values come from an independent native SQLite database,
     * reconfigured after open, never from changing Room's process-wide pool or global settings. */
    private class NativeFault(private val f: GpsDeliveryFixture) : AutoCloseable {
        private val name = "gps-guard-fault-${UUID.randomUUID()}.sqlite"
        private val helper = FrameworkSQLiteOpenHelperFactory().create(
            SupportSQLiteOpenHelper.Configuration.builder(f.storage.app).name(name)
                .callback(object : SupportSQLiteOpenHelper.Callback(1) {
                    override fun onConfigure(db: SupportSQLiteDatabase) { db.execSQL("PRAGMA synchronous=FULL") }
                    override fun onCreate(db: SupportSQLiteDatabase) { db.execSQL("CREATE TABLE fault(value INTEGER)") }
                    override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                }).build())
        init {
            helper.setWriteAheadLoggingEnabled(true)
            val sql = helper.writableDatabase
            sql.beginTransaction()
            try { requireDurableAccountCommit(sql) } finally { sql.endTransaction() }
        }
        fun normalAfterOpen() {
            helper.writableDatabase.execSQL("PRAGMA synchronous=NORMAL")
            helper.writableDatabase.query("PRAGMA synchronous").use { assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0)) }
        }
        fun deleteJournalAfterOpen() { helper.setWriteAheadLoggingEnabled(false) }
        fun view(writer: SupportSQLiteDatabase): SupportSQLiteDatabase {
            assertTrue("guard must already own the real Room writer", writer.inTransaction())
            return object : SupportSQLiteDatabase by writer {
                override fun query(query: String) = when (query.trim().lowercase()) {
                    "pragma synchronous", "pragma journal_mode" -> helper.writableDatabase.query(query)
                    else -> writer.query(query)
                }
            }
        }
        override fun close() { helper.close(); assertTrue(f.storage.app.deleteDatabase(name)) }
    }

    @Test fun afterOpenNormalFaultBeforeDestinationWriteRetainsFrozenIntentAndAllGpsPoints() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start()
            withContext(Dispatchers.IO) { f.db.runInTransaction { requireDurableAccountCommit(f.db.openHelper.writableDatabase) } }
            NativeFault(f).use { fault ->
                fault.normalAfterOpen()
                var notifications = 0
                val error = gpsRejects { GpsWorkoutFinalizer(f.account, f.gps,
                    durabilityView = fault::view, onCommitted = { notifications++ }).finish(id, f.inputs) }
                assertTrue(error.message.orEmpty().contains("FULL"))
                val payload = f.payload(id)
                assertEquals(2, f.route()!!.pointCount); assertEquals(0L, f.count("workout"))
                assertEquals(0L, f.count("hrSample")); assertEquals(0L, f.count("gpsWorkoutDelivery")); assertEquals(0, notifications)
                assertEquals(payload.row, GpsWorkoutFinalizer(f.account, f.gps).finish(id, f.changed))
                assertNull(f.route())
            }
        }
    }

    @Test fun afterDestinationCommitNormalFaultBlocksGpsDeleteButDoesNotSuppressPublication() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val repository = WhoopRepository(f.db)
            NativeFault(f).use { fault ->
                var delivered = false; var deleteCalls = 0
                val counts = mutableListOf<Int>()
                val error = gpsRejects { GpsWorkoutFinalizer(f.account, f.gps,
                    afterDestinationWrite = { fault.normalAfterOpen(); delivered = true },
                    beforeGpsDelete = { deleteCalls++ },
                    durabilityView = { if (delivered) fault.view(it) else it },
                    onCommitted = { counts += it.insertedHr; repository.publishGpsHrCommit(it) { true } },
                ).finish(id, f.inputs) }
                assertTrue(error.message.orEmpty().contains("FULL")); assertEquals(0, deleteCalls)
                val payload = f.payload(id)
                assertArrayEquals(payload.encode(), f.blob(payload, "payload"))
                assertEquals(id, f.route()!!.id); assertEquals(listOf(f.samples.size), counts)
                assertEquals(1L, repository.sleepSampleRevision.value)
                GpsWorkoutFinalizer(f.account, f.gps, onCommitted = {
                    assertEquals(0, it.insertedHr); assertFalse(repository.publishGpsHrCommit(it) { true })
                }).finish(id, f.changed)
                assertNull(f.route()); assertEquals(1L, repository.sleepSampleRevision.value)
            }
        }
    }

    @Test fun afterOpenNonWalFaultCannotUseMatchingRetainedArtifactToDeleteGps() = runBlocking {
        GpsDeliveryFixture().use { f ->
            val id = f.start(); val payload = f.committed(id)
            NativeFault(f).use { fault ->
                fault.deleteJournalAfterOpen()
                var deletion = false
                val error = gpsRejects {
                    withContext(Dispatchers.IO) {
                        GpsWorkoutFinalizer.settleCurrent(f.account, payload, fault::view) { deletion = true }
                    }
                }
                assertTrue(error.message.orEmpty().contains("WAL")); assertFalse(deletion)
                assertEquals(id, f.route()!!.id); assertArrayEquals(payload.encode(), f.blob(payload, "payload"))
            }
        }
    }
}
