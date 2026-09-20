package com.noop.push

import android.app.Application
import com.noop.account.AccountAppRuntime
import com.noop.account.AccountWriteRevokedException
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W4InputRuntimeNativeTest {
    private fun config() = ScoringConfigInput(null, "EDWARDS", false, true, false, null, 0, 0, "whoop-rsa-v1")

    @Test fun offlineIntentSurvivesSchedulingFailureAndRetirement() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            val journal = account.getDatabasePath("server_sync.sqlite")
            val runtime = ScoringInputRuntime(account, scheduled = { throw IllegalStateException("synthetic scheduler failure") })
            assertFalse(journal.exists())
            val source = runtime.captureSource(f.device)
            val mutation = runtime.saveProfile(f.profile(), source)
            assertEquals("awaiting_head", mutation.state)
            runtime.retire(); runtime.awaitRetirement()
            ScoringSyncDatabase.open(account).use { db ->
                assertEquals(mutation, db.dao().mutation(mutation.mutationId))
            }
        }
    }

    @Test fun concurrentSavesShareOneJournalAndKeepCapturedTimezoneAndSource() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val opened = AtomicInteger()
            val runtime = ScoringInputRuntime(account,
                clock = Clock.fixed(Instant.parse("2026-09-18T12:00:00Z"), ZoneOffset.UTC), scheduled = {},
                openDatabase = { opened.incrementAndGet(); ScoringSyncDatabase.open(it) })
            try {
                val source = runtime.captureSource("my-whoop")
                val profile = async { runtime.saveProfile(f.profile().copy(timezone = "Pacific/Kiritimati"), source) }
                val config = async { runtime.saveConfig(config(), "Pacific/Kiritimati", source) }
                val mutations = listOf(profile.await(), config.await())
                assertEquals(1, opened.get())
                mutations.forEach {
                    val body = JSONObject(it.body)
                    assertEquals("2026-09-19", body.getString("p_effective_day"))
                    assertEquals(source.serverDeviceId, body.getString("p_device"))
                    assertNotEquals(source.uploadSourceId, body.getString("p_device"))
                }
            } finally { runtime.retire(); runtime.awaitRetirement() }
        }
    }

    @Test fun retirementDuringJournalConstructionCannotCreateAnIntent() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val entered = CountDownLatch(1); val release = CountDownLatch(1)
            val scheduled = AtomicInteger()
            val runtime = ScoringInputRuntime(account, scheduled = { scheduled.incrementAndGet() }, openDatabase = {
                ScoringSyncDatabase.open(it).also { entered.countDown(); check(release.await(10, TimeUnit.SECONDS)) }
            })
            val source = runtime.captureSource(f.device)
            val saving = async { runCatching { runtime.saveProfile(f.profile(), source) } }
            try {
                assertTrue(entered.await(10, TimeUnit.SECONDS)); runtime.retire(); release.countDown()
                val error = withTimeout(10_000) { saving.await() }.exceptionOrNull()
                assertEquals(AuthFailure.STALE, (error as AccountAuthException).failure)
                runtime.awaitRetirement()
                assertEquals(0, scheduled.get())
                assertFalse(account.getDatabasePath("server_sync.sqlite").exists())
            } finally { release.countDown(); saving.cancelAndJoin(); runtime.retire(); runtime.awaitRetirement() }
        }
    }

    @Test fun explicitRetirementDuringRebaseRetainsOriginalConflict() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val original = ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                store.enqueue(f.key(), ScoringInputHead(f.key(), 0), "2026-09-18", f.profile().payload()).also {
                    store.retainFailure(it, "conflict")
                }
            }
            val rpc = f.rpc(account, ScoringRpcTransport { _, _, _, _ ->
                entered.complete(Unit); release.await()
                ScoringRpcReply(200, JSONObject().put("schemaVersion", 1).put("userId", f.owner.userID)
                    .put("sourceDeviceId", f.device).put("kind", "profile").put("entity", "primary").put("headRevision", 8).toString())
            })
            val runtime = ScoringInputRuntime(account, rpc, scheduled = {})
            val source = runtime.captureSource(f.device)
            val rebasing = async { runCatching { runtime.saveProfile(f.profile(), source, original.mutationId) } }
            try {
                withTimeout(5000) { entered.await() }; runtime.retire(); release.complete(Unit)
                assertTrue(withTimeout(5000) { rebasing.await() }.exceptionOrNull() is AccountWriteRevokedException)
                runtime.awaitRetirement()
                ScoringSyncDatabase.open(account).use { db ->
                    assertEquals("conflict", db.dao().mutation(original.mutationId)!!.state)
                    assertEquals(1, db.dao().entity(f.key().storageKey)!!.clientRevision)
                }
            } finally { release.complete(Unit); rebasing.cancelAndJoin(); runtime.retire(); runtime.awaitRetirement() }
        }
    }

    @Test fun appRuntimeOwnsInputRetirementAndSameAccountReentryGetsANewWriter() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val old = AccountAppRuntime(f.account())
            val source = old.scoringInputs.captureSource(f.device)
            old.close(); old.scoringInputs.awaitRetirement()
            val failure = runCatching { old.scoringInputs.saveProfile(f.profile(), source) }.exceptionOrNull()
            assertEquals(AuthFailure.STALE, (failure as AccountAuthException).failure)
            f.controller.clearSession(); f.controller.signIn("a", "synthetic")
            val successor = ScoringInputRuntime(f.account(), scheduled = {})
            try {
                assertEquals("awaiting_head", successor.saveProfile(f.profile(), successor.captureSource(f.device)).state)
                assertTrue(runCatching { successor.saveConfig(config(), "UTC", source) }.exceptionOrNull() is IllegalArgumentException)
            } finally { successor.retire(); successor.awaitRetirement() }
        }
    }

    @Test fun legacyCyclePreferenceCannotEnableAnyNewServerContextFlag() {
        W4NativeFixture().use { f ->
            f.account().getSharedPreferences("noop_prefs", 0).edit().putBoolean("noop.cycleTracking", true).commit()
            val payload = JSONObject(config().payload())
            for (name in listOf("journalContextEnabled", "cycleAwarenessEnabled", "daytimePersonalBaselineEnabled")) {
                assertEquals(false, payload.get(name))
            }
            assertFalse(payload.has("alreadyUnwell"))
            for (kind in listOf("context", "period", "imported_daily", "manual_workout")) {
                assertTrue(runCatching { ScoringInputKey(f.device, kind, "primary") }.exceptionOrNull() is IllegalArgumentException)
            }
        }
    }
}
