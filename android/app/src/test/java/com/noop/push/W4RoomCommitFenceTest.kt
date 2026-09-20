package com.noop.push

import android.app.Application
import com.noop.data.WhoopDatabase
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W4RoomCommitFenceTest {
    @Test fun sameAccountReentrySelectsOnlyFreshGenerationCaptureBinding() = runBlocking {
        W4NativeFixture().use { f ->
            val account = f.account(); val old = WhoopDatabase.get(account); old.openHelper.writableDatabase
            val source = SelfHostedPushSettings.from(account).sourceId()
            AccountPushCaptureBindings.bind(old, f.owner, source)
            assertSame(old, AccountPushCaptureBindings.binding(account.identity.context!!)!!.database)
            f.controller.clearSession(); f.controller.signIn("a", "synthetic")
            val current = f.account(); assertNull(AccountPushCaptureBindings.binding(current.identity.context!!))
            val fresh = WhoopDatabase.get(current); fresh.openHelper.writableDatabase
            AccountPushCaptureBindings.bind(fresh, f.owner, source)
            assertSame(fresh, AccountPushCaptureBindings.binding(current.identity.context!!)!!.database)
        }
    }
    @Test fun authRevocationAfterExecutedSqlRollsBackRealRoomTransaction() = runBlocking {
        W4NativeFixture().use { f ->
            val old = WhoopDatabase.get(f.account()); old.openHelper.writableDatabase
            val executed = CountDownLatch(1); val release = CountDownLatch(1)
            val executor = Executors.newSingleThreadExecutor()
            try {
                val result = executor.submit<Throwable?> {
                    try {
                        val sql = old.openHelper.writableDatabase
                        sql.beginTransaction()
                        try {
                            sql.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',1,60,0)")
                            sql.setTransactionSuccessful(); executed.countDown()
                            check(release.await(10, TimeUnit.SECONDS))
                        } finally { sql.endTransaction() }
                        null
                    } catch (e: Throwable) { e }
                }
                assertTrue(executed.await(10, TimeUnit.SECONDS))
                f.controller.clearSession(); release.countDown()
                val failure = result.get(10, TimeUnit.SECONDS)
                assertTrue(failure is com.noop.account.AccountWriteRevokedException)
                assertEquals(AuthFailure.STALE, (failure as com.noop.account.AccountWriteRevokedException).failure)
                old.openHelper.readableDatabase.query("SELECT count(*) FROM hrSample").use { assertTrue(it.moveToFirst()); assertEquals(0, it.getInt(0)) }
                f.controller.signIn("a", "synthetic")
                val fresh = WhoopDatabase.get(f.account()); assertNotSame(old, fresh)
                fresh.openHelper.writableDatabase.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',2,70,0)")
                fresh.openHelper.readableDatabase.query("SELECT count(*) FROM hrSample").use { assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0)) }
            } finally { release.countDown(); executor.shutdownNow() }
        }
    }
    @Test fun explicitRuntimeRetirementRollsBackNestedAndCompiledWrites() {
        W4NativeFixture().use { f ->
            val room = WhoopDatabase.get(f.account()); val db = room.openHelper.writableDatabase
            val statement = db.compileStatement("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',1,60,0)")
            db.beginTransaction(); db.beginTransactionNonExclusive(); statement.executeInsert(); db.setTransactionSuccessful(); db.endTransaction()
            db.setTransactionSuccessful(); room.retireWrites()
            try { db.endTransaction(); fail("retired commit") } catch (e: com.noop.account.AccountWriteRevokedException) { assertEquals(AuthFailure.STALE, e.failure) }
            db.query("SELECT count(*) FROM hrSample").use { assertTrue(it.moveToFirst()); assertEquals(0, it.getInt(0)) }
            try { statement.executeInsert(); fail("cached statement write") } catch (e: com.noop.account.AccountWriteRevokedException) { assertEquals(AuthFailure.STALE, e.failure) }
        }
    }
    @Test fun successfulTransactionAndUnmarkedRollbackRemainNative() {
        W4NativeFixture().use { f ->
            val db = WhoopDatabase.get(f.account()).openHelper.writableDatabase
            db.beginTransaction(); db.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',1,60,0)"); db.setTransactionSuccessful(); db.endTransaction()
            db.beginTransaction(); db.execSQL("INSERT INTO hrSample(deviceId,ts,bpm,synced) VALUES('fixture',2,70,0)"); db.endTransaction()
            db.query("SELECT ts FROM hrSample").use { assertTrue(it.moveToFirst()); assertEquals(1, it.getInt(0)); assertFalse(it.moveToNext()) }
        }
    }
}
