package com.noop.push

import android.app.Application
import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Actual SharedPreferences bytes written by an older client, read offline by the production store. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class LegacyBeatCacheNativeTest {
    @Test fun oldPersistedScopeKeepsRhrAndBoundsButCannotKeepUnqualifiedBeatValues() {
        val owner = "11111111-1111-1111-1111-111111111111"
        val day = "2026-09-16"
        val root = JSONObject(javaClass.getResource("/server_physiology_snapshot.json")!!.readText())
        val overlay = root.getJSONObject("server_scoring").put("algorithm_version", "frwhoop-server-1")
        val features = overlay.getJSONObject("features")
        for (key in features.keys()) features.getJSONObject(key).put("algorithm_version", "frwhoop-server-1")
            .put("canonical_qualification", "retained_legacy").put("feature_manifest_hash", JSONObject.NULL)
        overlay.getJSONObject("daily").put("hrv_rmssd_ms", 42).put("resting_hr_bpm", 51)
            .put("sleep_total_min", 450).put("sleep_in_bed_min", 480).put("resp_rate_bpm", 12).put("recovery", 77)
        val nights = overlay.getJSONArray("nights")
        for (i in 0 until nights.length()) nights.getJSONObject(i).put("algorithm_version", "frwhoop-server-1")
            .put("hrv_rmssd_ms", 42).put("resting_hr_bpm", 51).put("asleep_min", 450).put("in_bed_min", 480)
        val oldBytes = root.toString()
        val scope = ServerScoreCacheCodec.parseSnapshot(oldBytes, day, owner).scopeKey
        val context = RuntimeEnvironment.getApplication()
        val prefsName = "legacy-beat-cache-test"
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val key = JSONArray(listOf("v2", owner, day, scope)).toString()
        val pointer = JSONArray(listOf("selection", owner, day)).toString()
        val persisted = JSONObject().put("snapshot", oldBytes).put("fetchedAtMs", 1000).toString()
        assertTrue(prefs.edit().putString(key, persisted).putString(pointer, scope).commit())
        assertTrue(java.io.File(context.applicationInfo.dataDir, "shared_prefs/$prefsName.xml").isFile)
        val loaded = ServerScoreCacheStore(context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)).load(owner, day)!!
        assertNull(loaded.daily!!.hrvRmssdMs); assertNull(loaded.daily!!.respRateBpm)
        assertNull(loaded.daily!!.recovery); assertNull(loaded.daily!!.sleepTotalMin)
        assertEquals(51, loaded.daily!!.restingHrBpm); assertEquals(480.0, loaded.daily!!.sleepInBedMin!!, 0.0)
        assertTrue(loaded.nights.all { it.stages.isEmpty() && it.hrvRmssdMs == null && it.asleepMin == null })
        assertTrue(loaded.nights.all { it.inBedMin == 480.0 && it.restingHrBpm == 51 })
        assertNull(ServerScoreCacheStore(prefs).load("22222222-2222-2222-2222-222222222222", day))
        assertEquals(persisted, prefs.getString(key, null))
        assertEquals("beat_timing_unverified", ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV,
            true, day, loaded, 99.0).status)
    }
}
