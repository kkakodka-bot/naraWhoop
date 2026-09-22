package com.noop.push

import android.app.Application
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.net.Uri
import com.noop.account.AccountStorageContext
import com.noop.account.AccountStorageMutationLease
import com.noop.account.AccountWriteRevokedException
import com.noop.data.DataBackup
import com.noop.data.WhoopDatabase
import com.noop.ui.ProfileStore
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal class StorageMutationFixture : AutoCloseable {
    val app: Context = RuntimeEnvironment.getApplication()
    val a = AccountScope.create("https://restore.example.test", "10000000-0000-4000-8000-000000000001")
    val b = AccountScope.create(a.projectURL, "10000000-0000-4000-8000-000000000002")
    val controller = AccountSessionController(object : AccountCredentialStore {
        var saved: AccountSession? = AccountSession(a, "synthetic", "synthetic-refresh", Long.MAX_VALUE)
        override fun load(projectURL: String) = saved
        override fun save(session: AccountSession) { saved = session }
        override fun clear(projectURL: String) { saved = null }
    }, AccountAuthTransport { _, grant ->
        val owner = if ((grant as? AccountGrant.Password)?.email == "b") b else a
        AccountReply(200, """{"access_token":"synthetic","refresh_token":"synthetic-refresh","expires_in":3600,"user":{"id":"${owner.userID}"}}""")
    }).apply { configure(AccountConfiguration(a.projectURL, "synthetic-anon")) }
    private val installation = CloudAuthClient.installTestController(controller)
    fun account(base: Context = app) = AccountStorageContext(base, controller.identitySnapshot())
    fun login(owner: String) = runBlocking { controller.signIn(owner, "synthetic") }
    fun room(account: AccountStorageContext) = WhoopDatabase.get(account).also {
        it.openHelper.writableDatabase.execSQL("INSERT OR IGNORE INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',1,61,0)")
    }
    fun staged(account: AccountStorageContext): File {
        val room = room(account)
        room.openHelper.writableDatabase.query("PRAGMA wal_checkpoint(FULL)").use { assertTrue(it.moveToFirst()); assertEquals(0, it.getInt(0)) }
        val file = File.createTempFile("synthetic-backup-", ".sqlite", account.cacheDir)
        account.getDatabasePath(WhoopDatabase.DB_NAME).copyTo(file, overwrite = true)
        SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READWRITE).use {
            it.rawQuery("PRAGMA journal_mode=DELETE", null).use { cursor ->
                assertTrue(cursor.moveToFirst()); assertEquals("delete", cursor.getString(0))
            }
            it.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',99,77,0)")
        }
        return file
    }
    fun emptySettings(account: AccountStorageContext) = File.createTempFile("synthetic-settings-", ".json", account.cacheDir)
        .also { assertTrue(it.delete()) }
    override fun close() { WhoopDatabase.close(); installation.close() }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class AccountRestoreLeaseTest {
    @Test fun currentImportUsesRealValidationAndRestoresDatabase() {
        StorageMutationFixture().use { f ->
            val account = f.account()
            val backup = f.staged(account)
            assertEquals(DataBackup.ImportResult.NeedsRestart, DataBackup.importFrom(account, Uri.fromFile(backup)))
            SQLiteDatabase.openDatabase(account.getDatabasePath(WhoopDatabase.DB_NAME).path, null, SQLiteDatabase.OPEN_READONLY).use { sql ->
                sql.rawQuery("SELECT bpm FROM hrSample WHERE ts=99", null).use { assertTrue(it.moveToFirst()); assertEquals(77, it.getInt(0)) }
            }
        }
    }

    @Test fun currentRestoreAppliesSettingsAndKeepsOtherAccountDatabaseOpen() {
        StorageMutationFixture().use { f ->
            f.login("b")
            val b = f.account(); val bRoom = f.room(b)
            f.login("a")
            val a = f.account(); val backup = f.staged(a)
            val settings = f.emptySettings(a)
            // Use the real codec so this test does not guess the backup JSON envelope.
            settings.writeText(checkNotNull(com.noop.data.BackupSettingsCodec.encode(mapOf("profile.weightKg" to 82.0))))
            assertEquals(DataBackup.ImportResult.NeedsRestart, DataBackup.installStagedBackup(a, backup, settings))
            assertTrue(bRoom.isOpen)
            bRoom.openHelper.readableDatabase.query("SELECT count(*) FROM hrSample").use { assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0)) }
            assertEquals(82.0, ProfileStore.from(a).weightKg, 0.0)
            assertFalse(backup.exists()); assertFalse(settings.exists())
        }
    }

    @Test fun replacementByBAtQuiescenceCannotMutateAOrCloseB() = replacementAtQuiescence("b")
    @Test fun replacementByNewAAtQuiescenceCannotMutateSharedAccountFiles() = replacementAtQuiescence("a")

    @Test fun productionRestoreLeaseAloneBlocksSuccessorOpeningUntilRejection() {
        StorageMutationFixture().use { f ->
            val old = f.account(); val staged = f.staged(old); val settings = f.emptySettings(old)
            val quiesced = CountDownLatch(1); val release = CountDownLatch(1)
            val opening = CountDownLatch(1); val opened = CountDownLatch(1)
            val executor = Executors.newFixedThreadPool(2)
            try {
                // No test-owned namespace lock: this assertion depends on production restore's lease.
                val restore = executor.submit<DataBackup.ImportResult> {
                    DataBackup.installStagedBackup(old, staged, settings) {
                        quiesced.countDown(); check(release.await(10, TimeUnit.SECONDS))
                    }
                }
                assertTrue(quiesced.await(10, TimeUnit.SECONDS))
                f.login("a")
                val current = f.account()
                val successor = executor.submit<WhoopDatabase> {
                    opening.countDown()
                    WhoopDatabase.get(current).also { opened.countDown() }
                }
                assertTrue(opening.await(10, TimeUnit.SECONDS))
                assertFalse("production restore must exclude same-namespace opens", opened.await(150, TimeUnit.MILLISECONDS))
                release.countDown()
                assertTrue(restore.get(10, TimeUnit.SECONDS) is DataBackup.ImportResult.Failed)
                val room = successor.get(10, TimeUnit.SECONDS)
                room.openHelper.writableDatabase.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',2,62,0)")
                room.openHelper.readableDatabase.query("SELECT ts FROM hrSample ORDER BY ts").use { rows ->
                    val timestamps = mutableListOf<Long>()
                    while (rows.moveToNext()) timestamps += rows.getLong(0)
                    assertEquals(listOf(1L, 2L), timestamps)
                }
            } finally { release.countDown(); executor.shutdownNow(); assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS)) }
        }
    }

    private fun replacementAtQuiescence(next: String) {
        StorageMutationFixture().use { f ->
            val old = f.account(); val oldRoom = f.room(old)
            val staged = f.staged(old); val settings = f.emptySettings(old)
            val quiesced = CountDownLatch(1); val release = CountDownLatch(1)
            val inspected = CountDownLatch(1)
            val restoreResult = CompletableFuture<DataBackup.ImportResult>()
            val opening = CountDownLatch(1); val opened = CountDownLatch(1)
            val executor = Executors.newFixedThreadPool(2)
            try {
                val restore = executor.submit<DataBackup.ImportResult> {
                    // Inspect the rejected restore before the authorized successor's owner probe can
                    // create WAL/SHM files. This is the same reentrant lock used by restore and get().
                    AccountStorageMutationLease.capture(old).withStorageLock {
                        val result = DataBackup.installStagedBackup(old, staged, settings) {
                            quiesced.countDown(); check(release.await(10, TimeUnit.SECONDS))
                        }
                        restoreResult.complete(result)
                        check(inspected.await(10, TimeUnit.SECONDS))
                        result
                    }
                }
                assertTrue(quiesced.await(10, TimeUnit.SECONDS))
                assertFalse(oldRoom.isOpen)
                val path = old.getDatabasePath(WhoopDatabase.DB_NAME)
                val before = path.readBytes()
                val sidecars = listOf("-wal", "-shm", ".import-bak").associateWith { suffix ->
                    File(path.path + suffix).takeIf { it.exists() }?.readBytes()
                }
                f.login(next)
                val current = f.account()
                val nextRoom = executor.submit<WhoopDatabase> {
                    opening.countDown()
                    WhoopDatabase.get(current).also { opened.countDown() }
                }
                assertTrue(opening.await(10, TimeUnit.SECONDS))
                if (next == "a") assertFalse("same namespace must wait for restore lease", opened.await(150, TimeUnit.MILLISECONDS))
                else assertTrue("B must not be stopped by A's restore", opened.await(10, TimeUnit.SECONDS))
                release.countDown()
                assertTrue(restoreResult.get(10, TimeUnit.SECONDS) is DataBackup.ImportResult.Failed)
                if (next == "a") assertEquals("successor must still wait until inspection", 1L, opened.count)
                assertArrayEquals(before, path.readBytes())
                sidecars.forEach { (suffix, bytes) ->
                    val after = File(path.path + suffix).takeIf { it.exists() }?.readBytes()
                    assertArrayEquals(suffix, bytes, after)
                }
                inspected.countDown()
                assertTrue(restore.get(10, TimeUnit.SECONDS) is DataBackup.ImportResult.Failed)
                val currentRoom = nextRoom.get(10, TimeUnit.SECONDS)
                currentRoom.openHelper.writableDatabase.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',2,62,0)")
                assertFalse(staged.exists()); assertFalse(settings.exists())
                try { oldRoom.openHelper.writableDatabase; fail("closed old helper reopened") }
                catch (_: AccountWriteRevokedException) { }
            } finally {
                release.countDown(); inspected.countDown()
                executor.shutdownNow(); assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS))
            }
        }
    }

    @Test fun staleAIsRejectedBeforeQuiescingB() = staleBeforeQuiescence("b")
    @Test fun staleAIsRejectedBeforeQuiescingNewA() = staleBeforeQuiescence("a")

    private fun staleBeforeQuiescence(next: String) {
        StorageMutationFixture().use { f ->
            val old = f.account(); val backup = f.staged(old); val settings = f.emptySettings(old)
            f.login(next)
            val current = f.account(); val room = f.room(current)
            val before = current.getDatabasePath(WhoopDatabase.DB_NAME).readBytes()
            assertTrue(DataBackup.installStagedBackup(old, backup, settings) is DataBackup.ImportResult.Failed)
            assertTrue(room.isOpen)
            assertArrayEquals(before, current.getDatabasePath(WhoopDatabase.DB_NAME).readBytes())
            room.openHelper.writableDatabase.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',2,63,0)")
        }
    }

    @Test fun explicitRetirementAtQuiescencePreventsInstallWithoutAnAuthChange() {
        StorageMutationFixture().use { f ->
            val account = f.account(); val room = f.room(account)
            val staged = f.staged(account); val settings = f.emptySettings(account)
            var before: ByteArray? = null
            val result = DataBackup.installStagedBackup(account, staged, settings) {
                before = account.getDatabasePath(WhoopDatabase.DB_NAME).readBytes()
                room.retireWrites()
            }
            assertTrue(result is DataBackup.ImportResult.Failed)
            assertEquals(account.identity, f.controller.identitySnapshot())
            assertArrayEquals(checkNotNull(before), account.getDatabasePath(WhoopDatabase.DB_NAME).readBytes())
            assertFalse(staged.exists()); assertFalse(settings.exists())
        }
    }

    @Test fun lazyDatabaseOpenSharesTheRestoreLease() {
        StorageMutationFixture().use { f ->
            val account = f.account(); val lazyRoom = WhoopDatabase.get(account)
            val lease = AccountStorageMutationLease.capture(account)
            val started = CountDownLatch(1); val opened = CountDownLatch(1)
            val executor = Executors.newSingleThreadExecutor()
            try {
                val future = lease.withStorageLock {
                    val pending = executor.submit {
                        started.countDown(); lazyRoom.openHelper.writableDatabase; opened.countDown()
                    }
                    assertTrue(started.await(10, TimeUnit.SECONDS))
                    assertFalse(opened.await(150, TimeUnit.MILLISECONDS))
                    pending
                }
                future.get(10, TimeUnit.SECONDS)
                assertTrue(lazyRoom.isOpen)
            } finally { executor.shutdownNow(); assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS)) }
        }
    }

    @Test fun restoreDrainsExecutedSqlAndRoomRollbackWithoutHoldingIdentityLock() {
        StorageMutationFixture().use { f ->
            val account = f.account(); val room = f.room(account)
            val staged = f.staged(account); val settings = f.emptySettings(account)
            val executed = CountDownLatch(1); val release = CountDownLatch(1)
            val installed = CountDownLatch(1)
            val executor = Executors.newFixedThreadPool(2)
            try {
                val writer = executor.submit {
                    room.beginTransaction()
                    try {
                        room.openHelper.writableDatabase.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',88,88,0)")
                        room.setTransactionSuccessful()
                        executed.countDown(); check(release.await(10, TimeUnit.SECONDS))
                    } finally {
                        try { room.endTransaction(); fail("revoked transaction committed") }
                        catch (_: AccountWriteRevokedException) { }
                    }
                }
                assertTrue(executed.await(10, TimeUnit.SECONDS))
                val restore = executor.submit<DataBackup.ImportResult> {
                    DataBackup.installStagedBackup(account, staged, settings).also { installed.countDown() }
                }
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
                while (room.accountWriteFence!!.admitsWrites() && System.nanoTime() < deadline) Thread.yield()
                assertFalse(room.accountWriteFence!!.admitsWrites())
                assertFalse("install must await the executed transaction", installed.await(150, TimeUnit.MILLISECONDS))
                assertTrue(room.isOpen)
                release.countDown(); writer.get(10, TimeUnit.SECONDS)
                assertEquals(DataBackup.ImportResult.NeedsRestart, restore.get(10, TimeUnit.SECONDS))
                SQLiteDatabase.openDatabase(account.getDatabasePath(WhoopDatabase.DB_NAME).path, null, SQLiteDatabase.OPEN_READONLY).use { sql ->
                    sql.rawQuery("SELECT ts FROM hrSample ORDER BY ts", null).use { rows ->
                        val timestamps = mutableListOf<Long>()
                        while (rows.moveToNext()) timestamps += rows.getLong(0)
                        assertEquals(listOf(1L, 99L), timestamps)
                    }
                }
            } finally { release.countDown(); executor.shutdownNow(); assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS)) }
        }
    }
}
