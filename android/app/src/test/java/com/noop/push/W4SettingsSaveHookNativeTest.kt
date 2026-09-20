package com.noop.push

import android.app.Application
import com.noop.ui.NoopPrefs
import com.noop.ui.ProfileStore
import com.noop.ui.UnitPrefs
import com.noop.ui.HrvWindow
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.Shadows.shadowOf
import android.os.Looper

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W4SettingsSaveHookNativeTest {
    @Test fun actualProfileSettersQueueOnlyExplicitValuesAndRetainRapidEdits() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val inputs = ScoringInputRuntime(account, scheduled = {})
            val tasks = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val source = inputs.captureSource(f.device)
            val bridge = ScoringSettingsSync(account, inputs, tasks, { source }, { true }, { "UTC" })
            val jobs = mutableListOf<Job>()
            val profile = ProfileStore(account.getSharedPreferences("noop_profile", 0),
                onScoringChange = { store, config -> bridge.changed(store, config)?.let(jobs::add) })
            try {
                profile.age // Legacy getter migration must not turn a default into reported physiology.
                assertNull(profile.scoringProfile("UTC").age)
                profile.weightKg = 70.0
                jobs.last().join()
                profile.weightKg = 72.0
                jobs.last().join()
                ScoringSyncDatabase.open(account).use { db ->
                    val first = db.dao().pending(20).single()
                    val firstPayload = JSONObject(first.body).getJSONObject("p_payload")
                    assertEquals(70.0, firstPayload.getDouble("weightKg"), 0.0)
                    assertTrue(firstPayload.isNull("age")); assertTrue(firstPayload.isNull("heightCm")); assertTrue(firstPayload.isNull("sex"))
                    val store = ScoringSyncStore(account, db)
                    val sent = store.admitDraft(first, ScoringInputHead(first.key(), 0))
                    store.recordReceipt(sent, f.receipt(sent))
                    val next = store.pending().single()
                    assertEquals(2, next.clientRevision); assertEquals("awaiting_head", next.state)
                    assertEquals(72.0, JSONObject(next.body).getJSONObject("p_payload").getDouble("weightKg"), 0.0)
                    val admitted = store.admitDraft(next, ScoringInputHead(next.key(), 123))
                    assertEquals(123, JSONObject(admitted.body).getLong("p_expected_revision"))
                    assertEquals(sent.body, db.dao().mutation(first.mutationId)!!.body)
                }
            } finally { bridge.retire(); tasks.cancel(); inputs.retire(); inputs.awaitRetirement() }
        }
    }

    @Test fun submittedIntentAndNewerCapturedSettingsRemainHeldOnConflict() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            ScoringSyncDatabase.open(f.account()).use { db ->
                val store = ScoringSyncStore(f.account(), db)
                val first = store.enqueue(f.key(), ScoringInputHead(f.key(), 0), "2026-09-18", f.profile().payload())
                val next = store.enqueue(f.key(), null, "2026-09-18", f.profile().copy(weightKg = 71.0).payload(), queueFollowing = true)
                store.retainFailure(first, "conflict")
                assertTrue(store.pending().isEmpty())
                assertEquals("waiting_previous", db.dao().mutation(next.mutationId)!!.state)
                assertTrue(runCatching { store.enqueue(f.key(), ScoringInputHead(f.key(), 2), "2026-09-18",
                    f.profile().payload(), resolving = first.mutationId) }.exceptionOrNull() is IllegalStateException)
                assertEquals("conflict", db.dao().mutation(first.mutationId)!!.state)
                assertEquals(first.body, db.dao().mutation(first.mutationId)!!.body)
            }
        }
    }

    @Test fun realConfigurationPreferenceChangeReachesTheCapturedJournal() = runBlocking {
        W4NativeFixture().use { f ->
            val account = f.account()
            val committed = java.util.concurrent.CountDownLatch(1)
            val inputs = ScoringInputRuntime(account, scheduled = { committed.countDown() })
            val tasks = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val source = inputs.captureSource(f.device)
            val bridge = ScoringSettingsSync(account, inputs, tasks, { source }, { true }, { "UTC" })
            try {
                bridge.start()
                assertFalse(account.getDatabasePath("server_sync.sqlite").exists())
                UnitPrefs.setHrvWindow(account, HrvWindow.DEEP_SLEEP)
                shadowOf(Looper.getMainLooper()).idle()
                assertTrue(committed.await(5, java.util.concurrent.TimeUnit.SECONDS))
                withContext(Dispatchers.IO) { ScoringSyncDatabase.open(account).use { db ->
                    val mutation = db.dao().pending(20).single()
                    assertEquals("config", mutation.kind)
                    val payload = JSONObject(mutation.body).getJSONObject("p_payload")
                    assertTrue(payload.getBoolean("deepHrvWindow"))
                    assertEquals(source.serverDeviceId, payload.getString("sourceEra"))
                    assertFalse(payload.getBoolean("journalContextEnabled")); assertFalse(payload.getBoolean("cycleAwarenessEnabled"))
                } }
            } finally { bridge.retire(); tasks.cancel(); inputs.retire(); inputs.awaitRetirement() }
        }
    }

    @Test fun disabledUploadAndRetiredProfileHandleDoNotEnqueueOrOverwrite() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val inputs = ScoringInputRuntime(account, scheduled = {})
            val tasks = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val bridge = ScoringSettingsSync(account, inputs, tasks, { inputs.captureSource(f.device) }, { false })
            var current = true
            val profile = ProfileStore(account.getSharedPreferences("noop_profile", 0),
                onScoringChange = { store, config -> bridge.changed(store, config) }, canWrite = { current })
            try {
                profile.weightKg = 70.0
                assertFalse(account.getDatabasePath("server_sync.sqlite").exists())
                current = false; profile.weightKg = 80.0
                assertEquals(70.0, profile.weightKg, 0.0)
            } finally { bridge.retire(); tasks.cancel(); inputs.retire(); inputs.awaitRetirement() }
        }
    }
}
