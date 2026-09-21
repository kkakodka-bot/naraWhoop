package com.noop.push

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ServerScoreCacheCodecTest {
    private val owner = "11111111-1111-1111-1111-111111111111"
    private val day = "2026-09-16"
    private fun body(): JSONObject {
        val feature = JSONObject().put("status", "available").put("device_id", "device-a")
            .put("algorithm_version", "frwhoop-physiology-2").put("input_revision", 7)
            .put("canonical_qualification", "signed_reference_approval").put("feature_manifest_hash", "f".repeat(64))
        val features = JSONObject()
        for (key in listOf("sleep", "hrv", "respiration")) features.put(key, JSONObject(feature.toString()))
        val night = JSONObject().put("id", "episode").put("device_id", "device-a")
            .put("start_at", "2026-09-16T00:00:00Z").put("end_at", "2026-09-16T08:00:00Z")
            .put("hrv_rmssd_ms", 42).put("resting_hr_bpm", 51).put("resp_rate_bpm", 12)
            .put("hrv_summary", JSONObject().put("value", 42)).put("respiration_summary", JSONObject().put("value", 12))
            .put("recovery", 77).put("strain", 12).put("spo2_pct", 98).put("skin_temp_c", 34).put("skin_temp_dev_c", 0.2)
        return JSONObject().put("server_scoring", JSONObject().put("schema_version", 2).put("user_id", owner).put("day", day)
            .put("algorithm_version", "frwhoop-physiology-2").put("features", features).put("nights", JSONArray().put(night))
            .put("daily", JSONObject().put("hrv_rmssd_ms", 0).put("sleep_total_min", 480).put("resp_rate_bpm", 12)))
    }
    private fun parse(root: JSONObject) = ServerScoreCacheCodec.parseSnapshot(root.toString(), day, owner)

    @Test fun approvedFeaturesPreserveZeroAndMatchingNestedPhysiology() {
        val cache = parse(body())
        assertTrue(cache.features.values.all { it.isCanonicalAvailable })
        assertEquals(0.0, ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, true, day, cache, null).value!!, 0.0)
        assertEquals(42.0, cache.nights.single().hrvRmssdMs!!, 0.0)
        assertEquals(12.0, cache.nights.single().respRateBpm!!, 0.0)
    }

    @Test fun missingRevokedShadowAndMalformedAuthorizationNeverActivate() {
        for ((key, value) in listOf("canonical_qualification" to JSONObject.NULL, "canonical_qualification" to "revoked",
            "feature_manifest_hash" to "not-a-hash", "feature_manifest_hash" to JSONObject.NULL,
            "publication_status" to "shadow", "publication_status" to "revoked", "status" to "unavailable")) {
            val root = body()
            val features = root.getJSONObject("server_scoring").getJSONObject("features")
            for (feature in features.keys()) features.getJSONObject(feature).put(key, value)
            val cache = parse(root)
            assertTrue(key, cache.features.values.none { it.isCanonicalAvailable })
            for (metric in listOf(ServerVitalSelection.Metric.HRV, ServerVitalSelection.Metric.SLEEP, ServerVitalSelection.Metric.RESPIRATORY)) {
                val selected = ServerVitalSelection.resolve(metric, true, day, cache, null)
                assertNull(key, selected.value)
                assertEquals("unavailable", selected.displayDiagnostic.status)
            }
            assertNull(cache.nights.single().hrvRmssdMs)
            assertNull(cache.nights.single().respRateBpm)
        }
    }

    @Test fun sleepApprovalCannotAuthorizeDifferentFeatureOrSnapshot() {
        for ((key, value) in listOf("canonical_qualification" to JSONObject.NULL, "device_id" to "device-b",
            "algorithm_version" to "different-model", "input_revision" to 8, "status" to "unavailable")) {
            val root = body()
            val features = root.getJSONObject("server_scoring").getJSONObject("features")
            for (feature in listOf("hrv", "respiration")) features.getJSONObject(feature).put(key, value)
            val cache = parse(root)
            assertTrue(cache.features.getValue("sleep").isCanonicalAvailable)
            assertNull(cache.nights.single().hrvRmssdMs)
            assertNull(cache.nights.single().restingHrBpm)
            assertNull(cache.nights.single().respRateBpm)
            val night = JSONObject(cache.rawSnapshotJSON!!).getJSONObject("server_scoring").getJSONArray("nights").getJSONObject(0)
            for (field in listOf("hrv_rmssd_ms", "resting_hr_bpm", "hrv_summary", "resp_rate_bpm", "respiration_summary",
                "recovery", "strain", "spo2_pct", "skin_temp_c", "skin_temp_dev_c")) {
                assertFalse("$key: $field", night.has(field))
            }
        }
    }

    @Test fun retainedV1DoesNotRequireV2ApprovalAndWrongEpisodeScopeFails() {
        val root = body()
        val features = root.getJSONObject("server_scoring").getJSONObject("features")
        for (key in features.keys()) features.getJSONObject(key).apply {
            put("algorithm_version", "frwhoop-server-1"); remove("canonical_qualification"); remove("feature_manifest_hash")
        }
        assertTrue(parse(root).features.values.all { it.isCanonicalAvailable })
        for (key in listOf("user_id", "device_id", "algorithm_version")) {
            val invalid = JSONObject(root.toString())
            invalid.getJSONObject("server_scoring").getJSONArray("nights").getJSONObject(0).put(key, "other")
            assertTrue(key, runCatching { parse(invalid) }.isFailure)
        }
    }
}
