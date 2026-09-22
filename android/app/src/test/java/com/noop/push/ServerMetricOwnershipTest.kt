package com.noop.push

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ServerMetricOwnershipTest {
    private val owner = "11111111-1111-4111-8111-111111111111"
    private val device = "22222222-2222-4222-8222-222222222222"
    private val day = "2026-09-21"
    private val empty get() = ServerMetricOwnership("https://compute.invalid", owner, device)

    private fun cache(status: String = "available", qualified: Boolean = true, revision: Long? = 7,
                      value: Any = 0, reason: String? = null, owner: String = this.owner,
                      device: String = this.device): ServerScoreDayCache {
        val feature = JSONObject().put("status", status).put("algorithm_version", "frwhoop-physiology-2")
            .put("device_id", device).put("computed_at", "2026-09-21T10:00:00Z")
            .put("input_revision", revision ?: JSONObject.NULL).put("reason", reason ?: JSONObject.NULL)
        if (qualified) feature.put("canonical_qualification", "signed_reference_approval")
            .put("feature_manifest_hash", "f".repeat(64))
        val body = JSONObject().put("server_scoring", JSONObject().put("schema_version", 2)
            .put("user_id", owner).put("day", day).put("algorithm_version", "per_feature")
            .put("features", JSONObject().put("hrv", feature)).put("daily", JSONObject().put("hrv_rmssd_ms", value))
            .put("nights", org.json.JSONArray()).put("stale", status == "stale"))
        return ServerScoreCacheCodec.parseSnapshot(body.toString(), day, owner)
    }

    @Test fun partialQualifiedResultOwnsOnlyItsSerializedOutputs() {
        val ownership = empty.observe(cache())
        assertTrue(ownership.owns("hrv_rmssd_ms"))
        assertFalse(ownership.owns("sleep_sessions"))
        assertFalse(ownership.owns("current_hrv"))
        assertFalse(ownership.canRetireDailyKernel)
    }

    @Test fun nullFailureRevocationAndNavigationCannotRestartLocalFallback() {
        val ownership = empty.observe(cache())
        for ((status, qualified, reason) in listOf(Triple("pending", true, "queued"),
            Triple("unavailable", true, "failed"), Triple("unavailable", false, "unqualified_version"))) {
            val missing = cache(status, qualified, value = JSONObject.NULL, reason = reason)
            assertEquals(ownership, ownership.observe(missing))
            val selected = ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, false, day,
                ownership.presentation(missing, day), 99.0)
            assertTrue(selected.fromServer)
            assertNull(selected.value)
            assertEquals(reason, selected.status)
        }
        assertNull(ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, true, "2020-01-01",
            ownership.presentation(null, "2020-01-01"), 99.0).value)
    }

    @Test fun zeroAndUnownedLegacyMetricRemainDistinct() {
        val cache = cache()
        val presented = empty.observe(cache).presentation(cache, day)
        assertEquals(0.0, ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, true, day, presented, 99.0).value!!, 0.0)
        val sleep = ServerVitalSelection.resolve(ServerVitalSelection.Metric.SLEEP, true, day, presented, 480.0)
        assertFalse(sleep.fromServer)
        assertEquals(480.0, sleep.value!!, 0.0)
    }

    @Test fun scopeAndPublicationEvidenceAreRequiredBeforeClaim() {
        for (cache in listOf(cache(qualified = false), cache(revision = null),
            cache(owner = "33333333-3333-4333-8333-333333333333"), cache(device = "other-device"))) {
            assertEquals(empty, empty.observe(cache))
        }
    }

    @Test fun restartRestoresOnlyTheSameProjectOwnerAndDevice() {
        val original = empty.observe(cache())
        assertEquals(original, ServerMetricOwnership.restore(original.encode(), original.project, owner, device))
        for (scope in listOf(empty.copy(project = "https://other.invalid"), empty.copy(ownerId = "other-owner"),
            empty.copy(deviceId = "other-device"))) {
            assertTrue(ServerMetricOwnership.restore(original.encode(), scope.project, scope.ownerId, scope.deviceId).metrics.isEmpty())
        }
    }

    @Test fun olderPublicationCannotRollBackClaim() {
        val ownership = empty.observe(cache(revision = 9))
        assertEquals(ownership, ownership.observe(cache(revision = 8)))
    }

    @Test fun readFailureRetainsStaleRevisionButNeverLocalMissingValue() {
        val result = cache(revision = 9)
        val ownership = empty.observe(result)
        val presented = ownership.presentation(result, day, readFailed = true)!!
        assertTrue(presented.stale)
        assertEquals(9L, presented.features["hrv"]?.inputRevision)
        assertEquals("server_read_failed", presented.readFailure)
        val selected = ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, false, "2020-01-01",
            ownership.presentation(null, "2020-01-01", readFailed = true), 99.0)
        assertTrue(selected.fromServer)
        assertNull(selected.value)
        assertEquals("server_read_failed", selected.status)
    }
}
