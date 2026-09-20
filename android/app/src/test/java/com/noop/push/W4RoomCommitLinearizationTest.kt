package com.noop.push

import android.app.Application
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import com.noop.account.AccountFencedOpenHelperFactory
import com.noop.account.AccountWriteFence
import com.noop.account.AccountWriteRevokedException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W4RoomCommitLinearizationTest {
    @Test fun authRetirementCannotOvertakeAnAlreadyAdmittedNativeCommit() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val fence = AccountWriteFence(account)
            val armed = AtomicBoolean(); val atNativeEnd = CountDownLatch(1); val release = CountDownLatch(1)
            val retirementAttempted = CountDownLatch(1); val retirementDone = CountDownLatch(1)
            val intercept = object : SupportSQLiteOpenHelper.Factory {
                override fun create(configuration: SupportSQLiteOpenHelper.Configuration): SupportSQLiteOpenHelper {
                    val helper = FrameworkSQLiteOpenHelperFactory().create(configuration)
                    fun wrap(db: SupportSQLiteDatabase) = object : SupportSQLiteDatabase by db {
                        override fun endTransaction() {
                            if (armed.compareAndSet(true, false)) {
                                atNativeEnd.countDown(); check(release.await(10, TimeUnit.SECONDS))
                            }
                            db.endTransaction()
                        }
                    }
                    return object : SupportSQLiteOpenHelper by helper {
                        override val writableDatabase get() = wrap(helper.writableDatabase)
                        override val readableDatabase get() = wrap(helper.readableDatabase)
                    }
                }
            }
            val db = Room.databaseBuilder(account, ScoringSyncDatabase::class.java,
                account.getDatabasePath("commit-linearization.sqlite").absolutePath)
                .openHelperFactory(AccountFencedOpenHelperFactory(fence, intercept)).build().also {
                    it.writeFence = fence; it.accountIdentity = account.identity
                }
            val executor = Executors.newFixedThreadPool(2)
            try {
                val sql = db.openHelper.writableDatabase
                val writer = executor.submit {
                    sql.beginTransaction()
                    try {
                        sql.execSQL("INSERT INTO syncClient(singleton,clientId) VALUES(1,'synthetic')")
                        sql.setTransactionSuccessful(); armed.set(true)
                    } finally { sql.endTransaction() }
                }
                assertTrue(atNativeEnd.await(10, TimeUnit.SECONDS))
                val logout = executor.submit {
                    retirementAttempted.countDown()
                    f.controller.clearSession()
                    retirementDone.countDown()
                }
                assertTrue(retirementAttempted.await(10, TimeUnit.SECONDS))
                assertFalse("Logout must linearize after native commit", retirementDone.await(150, TimeUnit.MILLISECONDS))
                release.countDown(); writer.get(10, TimeUnit.SECONDS); logout.get(10, TimeUnit.SECONDS)
                assertEquals(0, retirementDone.count)
                sql.query("SELECT clientId FROM syncClient").use { assertTrue(it.moveToFirst()); assertEquals("synthetic", it.getString(0)) }
                try { sql.execSQL("UPDATE syncClient SET clientId='stale'"); fail("retired writer") }
                catch (e: AccountWriteRevokedException) { assertEquals(AuthFailure.STALE, e.failure) }
            } finally { release.countDown(); executor.shutdownNow(); executor.awaitTermination(10, TimeUnit.SECONDS); db.close() }
        }
    }

    @Test fun innerSuccessfulTransactionStillRollsBackWhenOuterIsNotSuccessful() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            ScoringSyncDatabase.open(f.account()).use { room ->
                val db = room.openHelper.writableDatabase
                db.beginTransaction()
                try {
                    db.beginTransactionNonExclusive()
                    try {
                        db.execSQL("INSERT INTO syncClient(singleton,clientId) VALUES(1,'synthetic')")
                        db.setTransactionSuccessful()
                    } finally { db.endTransaction() }
                } finally { db.endTransaction() }
                assertNull(room.dao().client())
                db.execSQL("INSERT INTO syncClient(singleton,clientId) VALUES(1,'next')")
                assertEquals("next", room.dao().client()!!.clientId)
            }
        }
    }
}
