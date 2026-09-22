package com.noop.push

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class ServerComputeContractTest {
    private val owner = "11111111-1111-4111-8111-111111111111"
    private val device = "22222222-2222-4222-8222-222222222222"
    private val source = "33333333-3333-4333-8333-333333333333"
    private val project = "https://compute.invalid"
    private val day = "2026-09-21"
    private fun body(): JSONObject {
        val families = JSONObject()
        ServerComputeContract.familyMetrics.forEach { (family, metrics) ->
            val values = JSONObject(); metrics.forEach { values.put(it, JSONObject.NULL) }
            families.put(family, JSONObject().put("owner", "server").put("metrics", JSONArray(metrics.toList()))
                .put("project", project).put("owner_id", owner).put("device_id", device).put("source_id", source)
                .put("window", day).put("timezone_id", "America/Los_Angeles")
                .put("status", "unsupported").put("reason", "qualified_producer_unavailable")
                .put("algorithm_version", "vps-only-1").put("configuration_version", "vps-only-1")
                .put("input_revision", 8).put("result_revision", "compute:17")
                .put("computed_at", "2026-09-22T07:01:00Z").put("observed_through", JSONObject.NULL)
                .put("values", values).put("details", JSONObject()))
        }
        val compute = JSONObject().put("mode", "final_hosted").put("policy_version", "vps-only-1")
            .put("project", project).put("owner_id", owner).put("source_id", source).put("device_id", device)
            .put("families", families)
        return JSONObject().put("server_scoring", JSONObject().put("schema_version", 2).put("day", day)
            .put("user_id", owner).put("algorithm_version", "per_feature").put("features", JSONObject().put("sleep", JSONObject().put("status", "unavailable")))
            .put("daily", JSONObject()).put("nights", JSONArray()).put("stale", false).put("compute", compute))
    }
    private fun family(root: JSONObject, key: String) = root.getJSONObject("server_scoring").getJSONObject("compute").getJSONObject("families").getJSONObject(key)
    private fun decode(root: JSONObject) = ServerScoreCacheCodec.parseSnapshot(root.toString(), day, owner)
    private fun available(root: JSONObject, value: Any) {
        family(root, "night_hrv").put("status", "available").put("algorithm_version", "frwhoop-physiology-2")
            .put("canonical_qualification", "signed_reference_approval").put("manifest_hash", "a".repeat(64))
            .put("feature_manifest_hash", "b".repeat(64)).put("result_revision", "sha256:" + "c".repeat(64))
            .put("configuration_version", JSONObject.NULL).getJSONObject("values").put("hrv_rmssd_ms", value)
    }
    @Test fun allFamiliesAndMissingRevisionsRoundTripThroughLedger() {
        val cache = decode(body())
        assertEquals(27, cache.compute!!.families.size)
        assertEquals(80, cache.ownedMetrics!!.size)
        val ledger = ServerMetricOwnership(project, owner, device).observe(cache)
        val restored = ServerMetricOwnership.restore(ledger.encode(), project, owner, device)
        assertEquals(ledger, restored)
        assertEquals(ServerComputeContract.metricIDs, restored.metrics)
        assertTrue(restored.canRetireDailyKernel)
        assertEquals("compute:17", cache.compute!!.families["spot_hrv"]!!.resultRevision)
    }
    @Test fun zeroNullAndEveryMissingStateNeverUseLocalFallback() {
        val root = body(); available(root, 0)
        var cache = decode(root)
        assertEquals(0.0, ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, false, day, cache, 77.0).value!!, 0.0)
        for (status in listOf("available", "unsupported", "insufficient_input", "insufficient_quality", "unqualified", "processing", "failed", "unavailable", "revoked")) {
            family(root, "night_hrv").put("status", status).getJSONObject("values").put("hrv_rmssd_ms", JSONObject.NULL)
            cache = decode(root)
            val selected = ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, false, day, cache, 77.0)
            assertTrue(selected.fromServer); assertNull(selected.value); assertNotNull(selected.resultRevision)
        }
    }
    @Test fun authorizationCannotBeRecoveredFromAnUnqualifiedNumber() {
        val root = body(); available(root, 42)
        family(root, "night_hrv").put("canonical_qualification", JSONObject.NULL)
        assertNull(decode(root).compute!!.families["night_hrv"]!!.number("hrv_rmssd_ms"))
        family(root, "night_hrv").put("canonical_qualification", "signed_reference_approval").put("feature_manifest_hash", "mismatch")
        assertNull(decode(root).compute!!.families["night_hrv"]!!.number("hrv_rmssd_ms"))
    }
    @Test fun wrongDeviceOwnerSourceDayOrFabricatedRevisionRejectWholeEnvelope() {
        for ((key, value) in listOf("device_id" to "other", "owner_id" to "other", "source_id" to "other", "window" to "2026-09-20", "result_revision" to "snapshot:9")) {
            val root = body(); family(root, "night_hrv").put(key, value)
            assertThrows(RuntimeException::class.java) { decode(root) }
        }
        val incomplete = body(); incomplete.getJSONObject("server_scoring").getJSONObject("compute").getJSONObject("families").remove("spot_hrv")
        assertThrows(RuntimeException::class.java) { decode(incomplete) }
    }
    @Test fun expiryIsASeparateAdmissionNotAReplayableMeasurement() {
        val root = body(); available(root, 42)
        family(root, "night_hrv").put("decision_id", "decision-a").put("expires_at", "2026-09-22T07:01:30Z")
        val f = decode(root).compute!!.families.getValue("night_hrv")
        assertTrue(f.usableDecision(java.time.Instant.parse("2026-09-22T07:01:00Z").toEpochMilli()))
        assertFalse(f.usableDecision(java.time.Instant.parse("2026-09-22T07:01:30Z").toEpochMilli()))
    }
}
