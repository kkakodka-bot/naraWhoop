package com.noop.push

import android.app.Application
import android.net.Uri
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import com.noop.data.DataBackup
import com.noop.data.DurableAccountOpenHelperFactory
import com.noop.data.WhoopDatabase
import com.noop.data.requireDurableAccountCommit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode
import java.util.UUID

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 34], application = Application::class)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class W2AccountDestinationDurabilityNativeTest {
    private fun assertWriter(room: WhoopDatabase) {
        room.runInTransaction {
            val sql = room.openHelper.writableDatabase
            requireDurableAccountCommit(sql)
            sql.query("PRAGMA synchronous").use { assertTrue(it.moveToFirst()); assertEquals(2, it.getInt(0)) }
        }
    }

    @Test fun freshRoomAndSeparateWriterThreadsUseFullWal(): Unit = runBlocking(Dispatchers.IO) {
        StorageMutationFixture().use { f ->
            val room = f.room(f.account())
            assertWriter(room)
            val executor = java.util.concurrent.Executors.newSingleThreadExecutor()
            try { executor.submit { assertWriter(room) }.get(10, java.util.concurrent.TimeUnit.SECONDS) }
            finally { executor.shutdownNow(); assertTrue(executor.awaitTermination(10, java.util.concurrent.TimeUnit.SECONDS)) }
        }
    }

    @Test fun simultaneousReaderTrafficDoesNotSubstituteAReaderForWriterVerification() {
        StorageMutationFixture().use { f ->
            val room = f.room(f.account())
            val start = java.util.concurrent.CountDownLatch(1)
            val ready = java.util.concurrent.CountDownLatch(4)
            val executor = java.util.concurrent.Executors.newFixedThreadPool(4)
            try {
                val readers = (1..3).map {
                    executor.submit {
                        ready.countDown(); check(start.await(10, java.util.concurrent.TimeUnit.SECONDS))
                        repeat(200) {
                            room.openHelper.readableDatabase.query("SELECT bpm FROM hrSample WHERE deviceId='fixture'").use {
                                assertTrue(it.moveToFirst()); assertEquals(61, it.getInt(0))
                            }
                        }
                    }
                }
                val writer = executor.submit {
                    ready.countDown(); check(start.await(10, java.util.concurrent.TimeUnit.SECONDS))
                    repeat(100) { assertWriter(room) }
                }
                assertTrue(ready.await(10, java.util.concurrent.TimeUnit.SECONDS)); start.countDown()
                (readers + writer).forEach { it.get(20, java.util.concurrent.TimeUnit.SECONDS) }
            } finally {
                start.countDown(); executor.shutdownNow()
                assertTrue(executor.awaitTermination(10, java.util.concurrent.TimeUnit.SECONDS))
            }
        }
    }

    @Test fun destinationGuardCannotBeSatisfiedOutsideItsWriterTransaction(): Unit = runBlocking(Dispatchers.IO) {
        StorageMutationFixture().use { f ->
            val room = f.room(f.account())
            assertThrows(IllegalStateException::class.java) { requireDurableAccountCommit(room.openHelper.writableDatabase) }
            assertWriter(room)
        }
    }

    @Test fun fullSynchronizationPrecedesActualCreateAndUpgradeCallbacks() {
        StorageMutationFixture().use { f ->
            val name = "synthetic-callback-order-${UUID.randomUUID()}.sqlite"
            val observed = mutableListOf<String>()
            fun helper(version: Int) = DurableAccountOpenHelperFactory().create(
                SupportSQLiteOpenHelper.Configuration.builder(f.app).name(name)
                    .callback(object : SupportSQLiteOpenHelper.Callback(version) {
                        override fun onCreate(db: SupportSQLiteDatabase) {
                            requireDurableAccountCommit(db)
                            observed += "create"
                            db.execSQL("CREATE TABLE proof(value INTEGER NOT NULL)")
                            db.execSQL("INSERT INTO proof VALUES(7)")
                        }
                        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) {
                            requireDurableAccountCommit(db)
                            assertEquals(1, oldVersion); assertEquals(2, newVersion)
                            observed += "upgrade"
                            db.execSQL("ALTER TABLE proof ADD COLUMN extra INTEGER")
                        }
                    }).build())
            try {
                helper(1).use { first -> first.setWriteAheadLoggingEnabled(true); first.writableDatabase }
                helper(2).use { second ->
                    second.setWriteAheadLoggingEnabled(true)
                    second.writableDatabase.query("SELECT value,extra FROM proof").use {
                        assertTrue(it.moveToFirst()); assertEquals(7, it.getInt(0)); assertTrue(it.isNull(1))
                    }
                }
                assertEquals(listOf("create", "upgrade"), observed)
            } finally { assertTrue(f.app.deleteDatabase(name)) }
        }
    }

    @Test fun freshGenerationReopenRetainsRowsAndReconfiguresWriter(): Unit = runBlocking(Dispatchers.IO) {
        StorageMutationFixture().use { f ->
            val old = f.account()
            assertWriter(f.room(old))
            WhoopDatabase.close()
            f.login("a")
            val current = f.account()
            assertEquals(old.root, current.root)
            assertNotEquals(old.identity.generation, current.identity.generation)
            val reopened = WhoopDatabase.get(current)
            assertWriter(reopened)
            reopened.openHelper.writableDatabase.query("SELECT bpm FROM hrSample WHERE deviceId='fixture' AND ts=1").use {
                assertTrue(it.moveToFirst()); assertEquals(61, it.getInt(0))
            }
        }
    }

    @Test fun restoredDeleteJournalBackupReopensAsFullWalWithoutLosingRows(): Unit = runBlocking(Dispatchers.IO) {
        StorageMutationFixture().use { f ->
            val old = f.account()
            val staged = f.staged(old)
            assertEquals(DataBackup.ImportResult.NeedsRestart, DataBackup.importFrom(old, Uri.fromFile(staged)))
            f.login("a")
            val room = WhoopDatabase.get(f.account())
            assertWriter(room)
            room.openHelper.writableDatabase.query("SELECT ts FROM hrSample WHERE deviceId='fixture' ORDER BY ts").use {
                val timestamps = mutableListOf<Long>()
                while (it.moveToNext()) timestamps += it.getLong(0)
                assertEquals(listOf(1L, 99L), timestamps)
            }
        }
    }

    @Test fun destinationGuardRejectsNormalSynchronousEvenInWal() {
        StorageMutationFixture().use { f ->
            val name = "synthetic-durability-${UUID.randomUUID()}.sqlite"
            val helper = FrameworkSQLiteOpenHelperFactory().create(
                SupportSQLiteOpenHelper.Configuration.builder(f.app).name(name)
                    .callback(object : SupportSQLiteOpenHelper.Callback(1) {
                        override fun onCreate(db: SupportSQLiteDatabase) = db.execSQL("CREATE TABLE proof(value INTEGER)")
                        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                        override fun onOpen(db: SupportSQLiteDatabase) { db.execSQL("PRAGMA synchronous=NORMAL") }
                    }).build())
            try {
                helper.setWriteAheadLoggingEnabled(true)
                val sql = helper.writableDatabase
                sql.beginTransaction()
                try {
                    assertThrows(IllegalStateException::class.java) { requireDurableAccountCommit(sql) }
                } finally { sql.endTransaction() }
            } finally { helper.close(); assertTrue(f.app.deleteDatabase(name)) }
        }
    }

    @Test fun durableFactoryRefusesNonWalInsteadOfDowngradingTheGuarantee() {
        StorageMutationFixture().use { f ->
            val name = "synthetic-no-wal-${UUID.randomUUID()}.sqlite"
            val helper = DurableAccountOpenHelperFactory().create(
                SupportSQLiteOpenHelper.Configuration.builder(f.app).name(name)
                    .callback(object : SupportSQLiteOpenHelper.Callback(1) {
                        override fun onCreate(db: SupportSQLiteDatabase) = db.execSQL("CREATE TABLE proof(value INTEGER)")
                        override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
                    }).build())
            try {
                helper.setWriteAheadLoggingEnabled(false)
                assertThrows(IllegalStateException::class.java) { helper.writableDatabase }
                assertTrue("failed opening must preserve the database", f.app.getDatabasePath(name).exists())
            } finally { helper.close(); assertTrue(f.app.deleteDatabase(name)) }
        }
    }
}
