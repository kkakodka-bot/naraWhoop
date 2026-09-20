package com.noop.push

import android.app.Application
import org.json.JSONObject
import org.json.JSONArray
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlinx.coroutines.runBlocking

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class W4SnapshotNativeTest {
    @Test fun typedNullOverridesLegacyAndCapabilitiesDoNotImplyNewMetrics() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val body = JSONObject(f.snapshot()).put("metrics", JSONObject("""{"hrv_rmssd_ms":{"value":null,"unit":"ms"},"skin_temp_dev_c":{"value":-0.5,"unit":"C"}}"""))
            val s = ServerSnapshotDecoder.decode(body.toString(), f.owner, "2026-09-18").snapshot!!
            assertNull(s.value("hrv_rmssd_ms")); assertNull(s.value("skin_temp_dev_c")); assertEquals(-0.5, s.metrics.getValue("skin_temp_dev_c").value!!, 0.0)
        }
    }
    @Test fun invalidOwnerDayTimezoneRevisionAndSleepRejectWithoutCoercion() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val invalid = listOf(
                JSONObject(f.snapshot()).put("userId", f.device), JSONObject(f.snapshot()).put("day", "2026-09-19"),
                JSONObject(f.snapshot()).put("timezone", "unknown/zone"), JSONObject(f.snapshot()).put("inputRevision", "2"),
                JSONObject(f.snapshot()).put("resultRevision", 0), JSONObject(f.snapshot()).put("sleep", JSONArray("""[{"id":"wrong"}]""")))
            invalid.forEach { body -> try { ServerSnapshotDecoder.decode(body.toString(), f.owner, "2026-09-18"); fail("invalid accepted") } catch (_: RuntimeException) { } }
        }
    }
    @Test fun historiesCannotReadFutureOrDuplicateDaysAndChartsCannotOverlap() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val invalid = listOf(
                JSONObject(f.snapshot()).put("history", JSONArray("""[{"day":"2026-09-19","metrics":{}}]""")),
                JSONObject(f.snapshot()).put("history", JSONArray("""[{"day":"2026-09-17","metrics":{}},{"day":"2026-09-17","metrics":{}}]""")),
                JSONObject(f.snapshot()).put("charts", JSONObject("""{"hr":[{"start":10,"end":20,"value":60},{"start":19,"end":30,"value":61}]}""")))
            invalid.forEach { body -> try { ServerSnapshotDecoder.decode(body.toString(), f.owner, "2026-09-18"); fail("invalid accepted") } catch (_: RuntimeException) { } }
        }
    }
    @Test fun actualRoomWholeSleepReplacementAndNewerNullSurviveReopen() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                val first = ServerSnapshotDecoder.decode(f.snapshot(sleep = f.sleep()), f.owner, "2026-09-18").snapshot!!
                store.accept(first, 1); assertEquals(1, store.load(first.day, "UTC")!!.first.sleep.size)
                val next = ServerSnapshotDecoder.decode(f.snapshot(9, 3, status = "no_data"), f.owner, first.day).snapshot!!
                store.accept(next, 2); assertEquals("no_data", store.accept(first, 3).status)
                assertNull(store.load(first.day, "UTC")!!.first.value("hrv_rmssd_ms"))
            }
            ScoringSyncDatabase.open(account).use { db ->
                val s = ScoringSyncStore(account, db).load("2026-09-18", "UTC")!!.first
                assertTrue(s.sleep.isEmpty()); assertEquals(9, s.resultRevision)
            }
        }
    }
    @Test fun sameRevisionCannotMutateResultButFreshnessEnvelopeCanChange() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val account = f.account()
            ScoringSyncDatabase.open(account).use { db ->
                val store = ScoringSyncStore(account, db)
                store.accept(ServerSnapshotDecoder.decode(f.snapshot(), f.owner, "2026-09-18").snapshot!!, 1)
                val freshness = JSONObject(f.snapshot()).put("pending", true).put("requestedInputRevision", 8)
                store.accept(ServerSnapshotDecoder.decode(freshness.toString(), f.owner, "2026-09-18").snapshot!!, 2)
                val changed = JSONObject(f.snapshot()).put("daily", JSONObject("""{"hrv_rmssd_ms":99}"""))
                try { store.accept(ServerSnapshotDecoder.decode(changed.toString(), f.owner, "2026-09-18").snapshot!!, 3); fail("immutable revision mutated") }
                catch (_: IllegalArgumentException) { }
                assertEquals(42.0, store.load("2026-09-18", "UTC")!!.first.value("hrv_rmssd_ms")!!, 0.0)
            }
        }
    }
    @Test fun pendingHasNoAuthoritativeEmptySnapshotAndRequestUsesV2() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val pending = JSONObject(f.snapshot()).put("status", "pending").put("resultRevision", JSONObject.NULL)
            val rpc = f.rpc(f.account(), ScoringRpcTransport { url, _, token, body ->
                assertTrue(url.endsWith("/get_server_score_snapshot_v2")); assertEquals("synthetic-access", token)
                assertEquals(setOf("p_day"), JSONObject(body).keys().asSequence().toSet())
                ScoringRpcReply(200, pending.toString())
            })
            assertNull(rpc.snapshot("2026-09-18", "UTC").snapshot)
        }
    }
    @Test fun authSwitchInsideTransportRejectsOldReply() = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
        W4NativeFixture().use { f ->
            val rpc = f.rpc(f.account(), ScoringRpcTransport { _, _, _, _ -> f.controller.clearSession(); ScoringRpcReply(200, f.snapshot()) })
            try { rpc.snapshot("2026-09-18"); fail("late response") } catch (e: AccountAuthException) { assertEquals(AuthFailure.STALE, e.failure) }
        }
    }
}
