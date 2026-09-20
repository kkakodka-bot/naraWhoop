package com.noop.push

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ServerRespirationSummaryTest {
    @Test fun actualScorerSnapshotSurvivesNativeReadback() {
        val bytes=javaClass.getResource("/server_scored_sleep_snapshot.json")!!.readText()
        val owner="11111111-1111-1111-1111-111111111111"
        val day="2026-09-17"
        val cache=ServerScoreClient.parseSnapshot(bytes,day,owner)
        val summary=ServerRespirationSummary.project(cache,day)!!
        assertEquals(12.0,summary.breathsPerMinute!!,0.1)
        assertEquals("main_sleep",summary.context)
        assertEquals("resp-spectrum-acf-1",summary.method)
        assertTrue(summary.coverage!!>0.9)
        assertEquals(summary.acceptedWindows,summary.totalWindows)
        assertNull(summary.reason)
        assertEquals(2,cache.nights.size)
        assertTrue(cache.nights.flatMap { it.stages }.any { it.state=="sleep_unstaged" })
        assertEquals(42L,cache.features["sleep"]!!.inputRevision)
        assertNotNull(cache.daily!!.hrvRmssdMs)
        assertTrue(runCatching { ServerScoreClient.parseSnapshot(bytes,day,"another-owner") }.isFailure)
    }

    private fun cache(version: String = "frwhoop-physiology-2", status: String = "available", scalar: Any = 16.0,
                      context: String = "main_sleep", median: Any = 16.0, coverage: Any = 0.5): ServerScoreDayCache {
        val summary = JSONObject().put("median_bpm", median).put("mean_bpm", 16.0)
            .put("distribution_bpm", JSONArray(listOf(18.0, 14.0, 16.0))).put("accepted_seconds", 180.0)
            .put("coverage", coverage).put("accepted_windows", 3).put("total_windows", 6).put("context", context)
            .put("method_version", "resp-spectrum-acf-1").put("calibration_status", "not_reference_validated")
        val overlay = JSONObject().put("schema_version", 2).put("user_id", "owner").put("day", "2026-09-18")
            .put("algorithm_version", version).put("features", JSONObject().put("respiration", JSONObject()
                .put("status", status).put("device_id", "strap").put("algorithm_version", version)))
            .put("daily", JSONObject().put("resp_rate_bpm", scalar).put("respiration_summary", summary)).put("nights", JSONArray())
        return ServerScoreClient.parseSnapshot(JSONObject().put("server_scoring", overlay).toString(), "2026-09-18", "owner")
    }

    @Test fun selectedSummaryRetainsMethodCoverageAndSortedDistribution() {
        val input = cache()
        val value = ServerRespirationSummary.project(input, input.day)!!
        assertEquals(16.0, value.breathsPerMinute!!, 0.0)
        assertEquals(16.0, value.mean!!, 0.0)
        assertEquals(listOf(14.0, 16.0, 18.0), value.distribution)
        assertEquals(0.5, value.coverage!!, 0.0)
        assertEquals(180.0, value.acceptedSeconds!!, 0.0)
        assertEquals(3, value.acceptedWindows)
        assertEquals(6, value.totalWindows)
        assertEquals("main_sleep", value.context)
        assertEquals("resp-spectrum-acf-1", value.method)
        assertEquals("not_reference_validated", value.calibrationStatus)
        assertNull(value.reason)
    }

    @Test fun staleSummaryIsRetainedWithoutLocalFallback() {
        val input = cache(status = "stale")
        assertEquals(16.0, ServerRespirationSummary.project(input, input.day)!!.breathsPerMinute!!, 0.0)
        assertEquals("stale", input.features["respiration"]!!.status)
    }

    @Test fun pendingRevisionDoesNotHideWhyTheCompletedMeasurementWasUnavailable() {
        val input = cache(scalar = JSONObject.NULL, median = JSONObject.NULL, coverage = 0)
        val root = JSONObject(input.rawSnapshotJSON!!)
        val overlay = root.getJSONObject("server_scoring")
        overlay.getJSONObject("features").getJSONObject("respiration")
            .put("status", "stale").put("reason", "newer_input_pending")
        overlay.getJSONObject("daily").put("respiration_unavailable_reason", "no_quality_eligible_windows")
        val cache = ServerScoreClient.parseSnapshot(root.toString(), input.day, input.ownerId)
        val value = ServerRespirationSummary.project(cache, input.day)!!
        assertNull(value.breathsPerMinute)
        assertEquals("newer_input_pending", value.reason)
        assertEquals("no_quality_eligible_windows", value.measurementReason)
        assertEquals("stale", cache.features["respiration"]!!.status)
    }

    @Test fun wrongDayOwnerOrSelectedSourceCannotReadSummary() {
        val input = cache()
        assertNull(ServerRespirationSummary.project(input, "2026-09-17"))
        assertNull(ServerRespirationSummary.project(input.copy(ownerId = "another-owner"), input.day))
        assertNull(ServerRespirationSummary.project(input.copy(rawSnapshotJSON = input.rawSnapshotJSON!!.replace("strap", "other-strap")), input.day))
    }

    @Test fun unavailableOrUnsupportedRateIsNotZero() {
        for (input in listOf(cache(status = "unavailable"), cache(scalar = JSONObject.NULL), cache(scalar = 0), cache(scalar = true))) {
            val value = ServerRespirationSummary.project(input, input.day)!!
            assertNull(value.breathsPerMinute)
            assertNotNull(value.reason)
        }
    }

    @Test fun awakeRestAndInconsistentSummaryCannotBecomeNightlyRate() {
        val active = cache(context = "awake_rest")
        assertEquals("incompatible_respiration_context", ServerRespirationSummary.project(active, active.day)!!.reason)
        for (input in listOf(cache(median = 14), cache(coverage = 1.1), cache(coverage = true))) {
            val value = ServerRespirationSummary.project(input, input.day)!!
            assertNull(value.breathsPerMinute)
            assertEquals("inconsistent_respiration_summary", value.reason)
        }
    }

    @Test fun legacyRateNeverClaimsV2QualityEvenWithUnexpectedSummaryFields() {
        val input = cache(version = "frwhoop-server-1")
        val value = ServerRespirationSummary.project(input, input.day)!!
        assertEquals(16.0, value.breathsPerMinute!!, 0.0)
        assertTrue(value.legacy)
        assertNull(value.mean)
        assertNull(value.coverage)
        assertNull(value.method)
        assertTrue(value.distribution.isEmpty())
        assertEquals("legacy_quality_unavailable", value.reason)
    }
}
