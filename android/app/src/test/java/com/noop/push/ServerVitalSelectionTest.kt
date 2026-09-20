package com.noop.push

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ServerVitalSelectionTest {
    private val day = "2026-09-16"
    private fun cache(day: String = this.day, daily: ServerScoreDailyCache? = null, stale: Boolean = false,
                      statuses: Map<String, String> = mapOf("respiration" to "available"), removing: List<String> = emptyList()): ServerScoreDayCache {
        val root = JSONObject(javaClass.getResource("/server_physiology_snapshot.json")!!.readText())
        val features = root.getJSONObject("server_scoring").getJSONObject("features")
        val scope = features.getJSONObject("hrv")
        for ((key, status) in statuses) {
            val entry = (features.optJSONObject(key) ?: JSONObject()).put("status", status)
            if (status != "unavailable") {
                if (!entry.has("device_id")) entry.put("device_id", scope.getString("device_id"))
                if (!entry.has("algorithm_version")) entry.put("algorithm_version", scope.getString("algorithm_version"))
            }
            features.put(key, entry)
        }
        for (key in removing) features.remove(key)
        return ServerScoreClient.parseSnapshot(root.toString(), this.day, "11111111-1111-1111-1111-111111111111")
            .copy(day = day, daily = daily, stale = stale)
    }

    @Test fun missingOverlayKeepsIndependentVitalsButNotServerSleep() {
        for (metric in ServerVitalSelection.Metric.entries) {
            val result = ServerVitalSelection.resolve(metric, true, day, null, 99.0)
            assertEquals(if (metric == ServerVitalSelection.Metric.SLEEP) null else 99.0, result.value)
            assertEquals(metric == ServerVitalSelection.Metric.SLEEP, result.fromServer)
        }
    }

    @Test fun missingServerValuesKeepLocalUntilThatMetricIsPublished() {
        val overlay = cache()
        val respiratory = ServerVitalSelection.resolve(ServerVitalSelection.Metric.RESPIRATORY, true, day, overlay, 99.0)
        assertEquals(99.0, respiratory.value!!, 0.0); assertFalse(respiratory.fromServer)
        val blankHrv = cache(daily = ServerScoreDailyCache(), statuses = mapOf("hrv" to "available", "sleep" to "available", "respiration" to "available"))
        val hrv = ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, true, day, blankHrv, 99.0)
        assertEquals(99.0, hrv.value!!, 0.0); assertFalse(hrv.fromServer)
    }

    @Test fun selectedServerValuesAndRealZeroWin() {
        val overlay = cache(daily = ServerScoreDailyCache(hrvRmssdMs = 0.0, restingHrBpm = 51, respRateBpm = 14.2))
        for ((metric, expected) in listOf(ServerVitalSelection.Metric.HRV to 0.0,
            ServerVitalSelection.Metric.RESTING_HR to 51.0, ServerVitalSelection.Metric.RESPIRATORY to 14.2))
            assertEquals(expected, ServerVitalSelection.resolve(metric, true, day, overlay, 99.0).value!!, 0.0)
    }

    @Test fun wrongDayCannotMasqueradeAsSelectedDay() {
        val overlay = cache("2026-09-15", ServerScoreDailyCache(hrvRmssdMs = 40.0, restingHrBpm = 60, respRateBpm = 15.0))
        for (metric in ServerVitalSelection.Metric.entries)
            assertEquals(if (metric == ServerVitalSelection.Metric.SLEEP) null else 99.0,
                ServerVitalSelection.resolve(metric, true, day, overlay, 99.0).value)
    }

    @Test fun localModeIsUnchangedAndIgnoresServer() {
        val overlay = cache(daily = ServerScoreDailyCache(hrvRmssdMs = 0.0, restingHrBpm = 51, respRateBpm = 14.2))
        for (metric in ServerVitalSelection.Metric.entries) {
            val result = ServerVitalSelection.resolve(metric, false, day, overlay, 99.0)
            assertEquals(99.0, result.value!!, 0.0); assertFalse(result.fromServer); assertNull(result.status)
        }
    }

    @Test fun retainedServerValueCarriesStaleness() {
        val result = ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, true, day,
            cache(daily = ServerScoreDailyCache(hrvRmssdMs = 42.0), stale = true), 99.0)
        assertEquals(42.0, result.value!!, 0.0); assertTrue(result.stale); assertEquals(day, result.day)
    }

    @Test fun restingHRUsesActualHrvFeatureScopeAndMetadata() {
        val overlay = cache(daily = ServerScoreDailyCache(restingHrBpm = 51), statuses = mapOf("hrv" to "stale"))
        val result = ServerVitalSelection.resolve(ServerVitalSelection.Metric.RESTING_HR, true, day, overlay, 99.0)
        assertEquals(51.0, result.value!!, 0.0); assertEquals("stale", result.status); assertTrue(result.stale)
        assertEquals("hrv", result.sourceFeature); assertEquals("22222222-2222-2222-2222-222222222222", result.deviceId)
        assertEquals("qualified-future-model-3", result.algorithmVersion)
    }

    @Test fun missingOrUnavailableSelectedFeatureRejectsEvenPresentDailyValues() {
        val daily = ServerScoreDailyCache(hrvRmssdMs = 40.0, restingHrBpm = 51, respRateBpm = 15.0)
        for ((metric, key) in listOf(ServerVitalSelection.Metric.HRV to "hrv", ServerVitalSelection.Metric.RESTING_HR to "hrv",
            ServerVitalSelection.Metric.RESPIRATORY to "respiration")) {
            for (overlay in listOf(cache(daily = daily, statuses = mapOf(key to "unavailable", "resting_hr" to "available")),
                cache(daily = daily, removing = listOf(key)))) {
                val result = ServerVitalSelection.resolve(metric, true, day, overlay, 99.0)
                assertEquals(99.0, result.value!!, 0.0); assertFalse(result.fromServer)
            }
        }
    }
    @Test fun sleepUsesSelectedDaySourceAndPreservesZeroWithoutLocalFallback() {
        for (minutes in listOf(0.0, 480.0)) {
            val overlay = cache(daily = ServerScoreDailyCache(sleepTotalMin = minutes), statuses = mapOf("sleep" to "stale"))
            val selected = ServerVitalSelection.resolve(ServerVitalSelection.Metric.SLEEP, true, day, overlay, 120.0)
            assertEquals(minutes, selected.value!!, 0.0); assertEquals("sleep", selected.sourceFeature)
            assertTrue(selected.stale); assertTrue(selected.fromServer)
            assertEquals(overlay.features["sleep"]?.deviceId, selected.deviceId)
            assertEquals(overlay.features["sleep"]?.algorithmVersion, selected.algorithmVersion)
        }
        val absent = cache(daily = ServerScoreDailyCache(), statuses = mapOf("sleep" to "available"))
        val pendingSleep = ServerVitalSelection.resolve(ServerVitalSelection.Metric.SLEEP, true, day, absent, 120.0)
        assertNull(pendingSleep.value); assertTrue(pendingSleep.fromServer)
        val unknown = cache(daily = ServerScoreDailyCache(sleepTotalMin = 480.0), statuses = mapOf("sleep" to "unavailable"))
        assertNull(ServerVitalSelection.resolve(ServerVitalSelection.Metric.SLEEP, true, day, unknown, 120.0).value)
        assertTrue(ServerVitalSelection.resolve(ServerVitalSelection.Metric.SLEEP, true, day, unknown, 120.0).fromServer)
        val local = ServerVitalSelection.resolve(ServerVitalSelection.Metric.SLEEP, false, day, unknown, 120.0)
        assertEquals(120.0, local.value!!, 0.0); assertFalse(local.fromServer)
    }

}
