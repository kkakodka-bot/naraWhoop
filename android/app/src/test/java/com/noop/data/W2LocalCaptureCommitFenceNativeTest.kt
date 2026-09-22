package com.noop.data

import android.app.Application
import com.noop.account.AccountWriteRevokedException
import com.noop.data.CaptureIndexNativeFixture.Companion.key
import com.noop.push.AuthFailure
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.SQLiteMode

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
@SQLiteMode(SQLiteMode.Mode.NATIVE)
class W2LocalCaptureCommitFenceNativeTest {
    @Test fun logoutAtRealIndexPrecommitRollsBackEveryExecutedIndexWrite() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(2, true)
            revokedAtCommit(f, { f.controller.clearSession() }) { it.register(capture) }
            assertEquals(0L, f.count("localCaptureResource")); assertEquals(0L, f.count("localCaptureMember"))
            assertTrue(f.file(capture).isFile)
        }
    }

    @Test fun sameAccountNewGenerationCannotLetOldProjectionAndMarkerCommit() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); f.store.register(capture)
            revokedAtCommit(f, { f.controller.clearSession(); f.controller.signIn("synthetic", "synthetic") }) {
                it.applyMember(capture, key(capture), CaptureFixtureProjection())
            }
            assertEquals(0L, f.count("captureProjectionFixture")); assertEquals(0, f.state(key(capture)))
            val freshRoom = WhoopDatabase.get(f.account()); assertNotSame(f.room, freshRoom)
            val freshFence = checkNotNull(freshRoom.accountWriteFence)
            val fresh = LocalCaptureStore(f.owner, object : com.noop.account.CaptureAdmission {
                override fun <T> withCurrent(block: () -> T): T = freshFence.commit(block)
            }, { freshRoom.openHelper.writableDatabase })
            assertEquals(CaptureApplyResult.APPLIED, fresh.applyMember(capture, key(capture), CaptureFixtureProjection()))
            assertEquals(1, f.state(key(capture)))
        }
    }

    @Test fun anotherOwnerAtPrecommitCannotInheritAnyProjection() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); f.store.register(capture)
            revokedAtCommit(f, {
                f.controller.clearSession(); f.nextUserID = UUID.randomUUID().toString(); f.controller.signIn("synthetic", "synthetic")
            }) { it.applyMember(capture, key(capture), CaptureFixtureProjection()) }
            assertEquals(0L, f.count("captureProjectionFixture")); assertEquals(0, f.state(key(capture)))
            val other = WhoopDatabase.get(f.account()).openHelper.writableDatabase
            other.query("SELECT userID FROM localAccountOwner").use { it.moveToFirst(); assertEquals(f.nextUserID, it.getString(0)) }
            val hasIndex = other.query("SELECT count(*) FROM sqlite_master WHERE name='localCaptureResource'").use {
                it.moveToFirst(); it.getInt(0) == 1
            }
            // Room42 has no capture tables; Room43 creates them, but never inherits another owner's rows.
            if (hasIndex) for (table in listOf("localCaptureResource", "localCaptureMember")) {
                other.query("SELECT count(*) FROM $table").use { it.moveToFirst(); assertEquals(0L, it.getLong(0)) }
            }
        }
    }

    @Test fun explicitRetirementAfterSqlRollsBackDestinationAndMarker() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); f.store.register(capture)
            revokedAtCommit(f, { f.room.retireWrites() }) { it.applyMember(capture, key(capture), CaptureFixtureProjection()) }
            assertEquals(0L, f.count("captureProjectionFixture")); assertEquals(0, f.state(key(capture)))
        }
    }

    @Test fun ownerMutationDuringProjectionCannotCommitDespiteCurrentAuth() = runBlocking {
        CaptureIndexNativeFixture().use { f ->
            val capture = f.capture(); f.store.register(capture)
            val delegate = CaptureFixtureProjection()
            val projection = object : CaptureMemberProjection {
                override fun write(database: androidx.sqlite.db.SupportSQLiteDatabase, input: CaptureProjectionInput): CaptureProjectionDecision {
                    delegate.write(database, input)
                    database.execSQL("UPDATE localAccountOwner SET userID=?", arrayOf(UUID.randomUUID().toString()))
                    return CaptureProjectionDecision.RECORDED
                }
                override fun destinationMatches(database: androidx.sqlite.db.SupportSQLiteDatabase, input: CaptureProjectionInput) = delegate.destinationMatches(database, input)
            }
            try { f.store.applyMember(capture, key(capture), projection); fail("owner changed before commit") }
            catch (e: CaptureIndexException) { assertEquals(CaptureIndexFailure.OWNER_MISMATCH, e.failure) }
            assertEquals(0L, f.count("captureProjectionFixture")); assertEquals(0, f.state(key(capture)))
            f.db.query("SELECT userID FROM localAccountOwner").use { it.moveToFirst(); assertEquals(f.owner.scope.userID, it.getString(0)) }
        }
    }

    private suspend fun revokedAtCommit(
        fixture: CaptureIndexNativeFixture,
        revoke: suspend () -> Unit,
        operation: suspend (LocalCaptureStore) -> Any,
    ) {
        val reached = CountDownLatch(1); val release = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val store = fixture.store { reached.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
            val result = executor.submit<Throwable?> {
                try { runBlocking { operation(store) }; null } catch (failure: Throwable) { failure }
            }
            assertTrue("real SQLite writes must precede revocation", reached.await(10, TimeUnit.SECONDS))
            revoke(); release.countDown()
            val failure = result.get(10, TimeUnit.SECONDS)
            assertTrue("expected generation revocation, got $failure", failure is AccountWriteRevokedException)
            assertEquals(AuthFailure.STALE, (failure as AccountWriteRevokedException).failure)
        } finally { release.countDown(); executor.shutdownNow() }
    }
}
