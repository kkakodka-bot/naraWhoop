package com.noop.push

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ServerHrvSeriesTest {
    private val day = "2026-09-18"
    private val start = 1789689600L

    private fun row(offset: Int = 0, value: Double = 40.0, context: String = "quiet_rest") = JSONObject()
        .put("measurement_schema_version", 1).put("feature", "hrv").put("user_id", "owner").put("device_id", "device")
        .put("start", start + offset).put("end", start + offset + 300).put("metric", "rmssd").put("unit", "ms")
        .put("input_revision", "42").put("observed_rmssd_ms", value).put("measurement_valid", true).put("reason", JSONObject.NULL)
        .put("context", context).put("baseline_eligible", true).put("source", "whoop5").put("modality", "ppg_prv")
        .put("algorithm_version", "rmssd-5m-v2").put("observed_time_fraction", .96)
        .put("baseline", JSONObject().put("effective_sample_count", 31).put("robust_z", 8.5))

    private fun cache(rows: List<Any>, status: String = "fresh", version: String = "frwhoop-physiology-2"): ServerScoreDayCache {
        val feature = JSONObject().put("status", status).put("device_id", "device").put("algorithm_version", version)
            .put("input_revision", 42).put("observed_through", "2026-09-18T00:30:00Z")
        val overlay = JSONObject().put("schema_version", 2).put("user_id", "owner").put("day", day)
            .put("algorithm_version", "per_feature").put("features", JSONObject().put("hrv", feature))
            .put("daily", JSONObject().put("hrv_rmssd_ms", 999)).put("measurements", JSONArray(rows)).put("nights", JSONArray())
        val parsed = ServerScoreClient.parseSnapshot(JSONObject().put("server_scoring", overlay).toString(), day, "owner", 1000)
        val store = ServerScoreCacheStore(SelfHostedPushSettingsTest.FakePushPrefs())
        store.upsert(parsed)
        return store.load("owner", day)!!
    }

    @Test fun zeroUnavailableAndMissingBucketsRemainDistinct() {
        val invalid = row(600, 500.0).put("measurement_valid", false).put("reason", "unverified_clock")
        val series = ServerHrvSeries.from(cache(listOf(row(value = 0.0), invalid)), day)
        assertEquals(3, series.windows.size)
        assertEquals(0.0, series.windows[0].rmssdMs!!, 0.0)
        assertTrue(series.windows[0].measurementValid)
        assertFalse(series.windows[0].isGap)
        assertNull(series.windows[1].rmssdMs)
        assertEquals("window_missing", series.windows[1].reason)
        assertTrue(series.windows[1].isGap)
        assertNull(series.windows[2].rmssdMs)
        assertEquals("unverified_clock", series.windows[2].reason)
        assertFalse(series.windows[2].isGap)
        assertEquals("2026-09-18T00:30:00Z", series.observedThrough)
    }

    @Test fun contextBaselineCountAndHighValuesSurviveWithoutClipping() {
        val contexts = listOf("sleep", "nap", "quiet_rest", "active", "mixed", "unknown")
        val series = ServerHrvSeries.from(cache(contexts.mapIndexed { index, context -> row(index * 300, 450.0, context) }), day)
        assertEquals(contexts, series.windows.map { it.context })
        assertEquals(listOf(true, true, true, false, false, false), series.windows.map { it.baselineEligible })
        assertTrue(series.windows.all { it.measurementValid && it.rmssdMs == 450.0 && it.baselineEffectiveSampleCount == 31 })
        assertEquals(8.5, series.windows[2].baselineRobustZ!!, 0.0)
        assertNull(series.windows[3].baselineRobustZ)
        assertEquals("whoop5", series.windows[0].source)
        assertEquals("ppg_prv", series.windows[0].modality)
        assertEquals("rmssd-5m-v2", series.windows[0].methodVersion)
        assertEquals(.96, series.windows[0].observedTimeFraction!!, 0.0)
    }

    @Test fun dailyAvailabilityNeverReplacesWindowValidityOrInventsWindows() {
        assertTrue(ServerHrvSeries.from(cache(emptyList()), day).windows.isEmpty())
        val unavailable = ServerHrvSeries.from(cache(listOf(row()), status = "unavailable"), day)
        assertEquals("unavailable", unavailable.featureStatus)
        assertEquals(40.0, unavailable.windows.first().rmssdMs!!, 0.0)
        assertTrue(ServerHrvSeries.from(cache(listOf(row()), version = "frwhoop-server-1"), day).windows.isEmpty())
        assertTrue(ServerHrvSeries.from(cache(listOf(row())), "2026-09-17").windows.isEmpty())
    }

    @Test fun ownerDeviceRevisionSchemaAndMetricFences() {
        for ((key, value) in listOf("user_id" to "other", "device_id" to "other", "input_revision" to "43",
            "measurement_schema_version" to 2, "metric" to "sdnn", "unit" to "s", "start" to start + 1)) {
            assertTrue(key, ServerHrvSeries.from(cache(listOf(row().put(key, value))), day).windows.isEmpty())
        }
        assertTrue(ServerHrvSeries.from(cache(listOf(row())).copy(ownerId = "other"), day).windows.isEmpty())
    }

    @Test fun duplicatesCollapseAndConflictingValuesFailClosed() {
        assertEquals(1, ServerHrvSeries.from(cache(listOf(row(), row())), day).windows.size)
        val conflict = ServerHrvSeries.from(cache(listOf(row(), row(value = 41.0))), day).windows.first()
        assertNull(conflict.rmssdMs)
        assertEquals("conflicting_window_records", conflict.reason)
        assertFalse(conflict.baselineEligible)
    }

    @Test fun malformedNumericAndValidityFieldsDoNotBecomeMeasurements() {
        for ((key, value) in listOf("observed_rmssd_ms" to true, "measurement_valid" to 1, "reason" to 5)) {
            val parsed = ServerHrvSeries.from(cache(listOf(row().put(key, value))), day).windows.first()
            assertFalse(key, parsed.measurementValid)
            assertNull(key, parsed.rmssdMs)
        }
        assertEquals(1, ServerHrvSeries.from(cache(listOf("malformed", row())), day).windows.size)
    }
}
