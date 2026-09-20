package com.noop.push

import android.app.Application
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W4RepositoryNativeTest {
    @Test fun realRepositoryRetainsPendingAndOfflineThenAtomicallyClearsWithNewerNoData() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val tasks = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            var response: String? = f.snapshot(sleep = f.sleep())
            val rpc = f.rpc(account, ScoringRpcTransport { _, _, _, _ -> ScoringRpcReply(200, response ?: throw java.io.IOException("offline")) })
            val repo = ServerScoreRepository(account, tasks, { "UTC" }, rpc, { true })
            try {
                repo.refreshDay("2026-09-18"); assertEquals(1, repo.days.value.getValue("2026-09-18").snapshot!!.sleep.size)
                val sleep = repo.sleepDays.value.getValue("2026-09-18")
                assertEquals(f.device, sleep.sourceDeviceId); assertEquals(1, sleep.sessions.size)
                assertEquals(1, sleep.sessions.single().stages.size)
                response = JSONObject(f.snapshot()).put("status", "pending").put("pending", true).put("resultRevision", JSONObject.NULL).toString()
                repo.refreshDay("2026-09-18")
                val pending = repo.days.value.getValue("2026-09-18"); assertTrue(pending.pending); assertTrue(pending.cached)
                assertEquals(7, pending.snapshot!!.resultRevision)
                assertTrue(repo.sleepDays.value.getValue("2026-09-18").pending)
                assertEquals(sleep.sessions, repo.sleepDays.value.getValue("2026-09-18").sessions)
                response = null; repo.refreshDay("2026-09-18"); assertEquals(7, repo.days.value.getValue("2026-09-18").snapshot!!.resultRevision)
                response = f.snapshot(10, 3, status = "no_data"); repo.refreshDay("2026-09-18")
                val empty = repo.days.value.getValue("2026-09-18").snapshot!!
                assertEquals(10, empty.resultRevision); assertTrue(empty.sleep.isEmpty()); assertNull(empty.value("hrv_rmssd_ms"))
                assertTrue(repo.sleepDays.value.getValue("2026-09-18").sessions.isEmpty())
                assertNull(repo.sleepDays.value.getValue("2026-09-18").totalMinutes)
            } finally { repo.retire(); tasks.cancel(); repo.awaitRetirement() }
        }
    }
    @Test fun suspendedFetchCannotPublishAfterExplicitRetirement() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val tasks = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
            val rpc = f.rpc(account, ScoringRpcTransport { _, _, _, _ -> entered.complete(Unit); release.await(); ScoringRpcReply(200, f.snapshot()) })
            val repo = ServerScoreRepository(account, tasks, { "UTC" }, rpc, { true })
            val fetching = async { repo.refreshDay("2026-09-18") }
            try {
                withTimeout(5000) { entered.await() }; repo.retire(); release.complete(Unit); fetching.await()
                assertTrue(repo.days.value.isEmpty())
                assertTrue(repo.sleepDays.value.isEmpty())
            } finally { release.complete(Unit); fetching.cancelAndJoin(); repo.retire(); tasks.cancel(); repo.awaitRetirement() }
        }
    }
    @Test fun historySelectionUsesHeadNotEffectiveRevisionAndRejectsFuturePayload() {
        W4NativeFixture().use { f ->
            val body = JSONObject().put("schemaVersion", 1).put("userId", f.owner.userID).put("sourceDeviceId", f.device)
                .put("kind", "profile").put("entity", "primary").put("headRevision", 100).put("revision", 20)
                .put("effectiveDay", "2026-09-10").put("deleted", false).put("payload", JSONObject(f.profile().payload()))
            val result = ScoringHistoryValue.decode(body.toString(), f.owner, f.key(), "2026-09-18")
            assertEquals(100, result.headRevision); assertEquals(20L, result.revision)
            try { ScoringHistoryValue.decode(body.put("effectiveDay", "2026-09-19").toString(), f.owner, f.key(), "2026-09-18"); fail("future input") }
            catch (_: IllegalArgumentException) { }
            body.put("revision", JSONObject.NULL).put("effectiveDay", JSONObject.NULL).put("deleted", JSONObject.NULL).put("payload", JSONObject.NULL)
            assertEquals(100, ScoringHistoryValue.decode(body.toString(), f.owner, f.key(), "2026-09-18").headRevision)
        }
    }
    @Test fun capturedSourceKeepsIntakeDeviceNotUploaderAndRejectsAnotherGeneration() = runBlocking(Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account(); val source = ScoringInputSource.capture(account, f.device.uppercase())
            assertEquals(f.device, source.serverDeviceId); assertNotEquals(source.uploadSourceId, source.serverDeviceId)
            val raw = ScoringInputSource.capture(account, "my-whoop")
            assertNotEquals(raw.serverDeviceId, ScoringInputSource.canonicalDevice(f.device, "my-whoop"))
            f.controller.clearSession(); f.controller.signIn("a", "synthetic")
            val current = f.account()
            ScoringSyncDatabase.open(current).use { db ->
                val coordinator = ScoringInputCoordinator(current, ScoringSyncStore(current, db), scheduled = {})
                try { coordinator.saveProfile(f.profile(), source); fail("stale source capture") } catch (_: IllegalArgumentException) { }
                assertTrue(db.dao().pending(20).isEmpty())
            }
        }
    }
    @Test fun staleHistoryWorkExitsBeforeCreatingJournalOrReadingCredentials() = runBlocking {
        W4NativeFixture().use { f ->
            val request = ScoringInputWorker.request(f.account())
            assertEquals(2, request.workSpec.input.keyValueMap.size)
            f.controller.clearSession()
            val worker = androidx.work.testing.TestListenableWorkerBuilder<ScoringInputWorker>(org.robolectric.RuntimeEnvironment.getApplication())
                .setInputData(request.workSpec.input).build()
            assertEquals(androidx.work.ListenableWorker.Result.success(), worker.doWork())
        }
    }
}
