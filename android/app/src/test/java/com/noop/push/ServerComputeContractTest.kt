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
    private val duplicatedDailyMetrics = listOf("hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm",
        "sleep_total_min", "sleep_in_bed_min", "sleep_awake_min", "sleep_light_min", "sleep_deep_min",
        "sleep_rem_min", "sleep_efficiency", "disturbances", "resp_rate_bpm", "recovery", "strain",
        "spo2_pct", "skin_temp_c", "skin_temp_dev_c")
    private val sleepDailyCompatibilityKeys = listOf("sleep_onset_at", "wake_onset_at", "sleep_unstaged_min",
        "state_unknown_min", "off_body_min", "main_sleep_group_id", "opportunity_kind", "full_day_sleep_epochs")
    private val featureBackedFamilies = mapOf("night_hrv" to "hrv", "current_hrv" to "hrv", "sleep" to "sleep",
        "respiration" to "respiration", "recovery" to "hrv", "strain_energy" to "hrv", "oxygen" to "hrv",
        "temperature" to "hrv")
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
                .put("freshness", "unavailable").put("values", values).put("details", JSONObject()))
        }
        val compute = JSONObject().put("mode", "final_hosted").put("policy_version", "vps-only-1")
            .put("project", project).put("owner_id", owner).put("source_id", source).put("device_id", device)
            .put("day", day).put("families", families)
        val daily = JSONObject(); (duplicatedDailyMetrics + sleepDailyCompatibilityKeys +
            listOf("hrv_summary", "heart_rate_windows", "respiration_summary")).forEach { daily.put(it, JSONObject.NULL) }
        val features = JSONObject(); listOf("hrv", "sleep", "respiration").forEach {
            features.put(it, JSONObject().put("status", "unavailable"))
        }
        return JSONObject().put("server_scoring", JSONObject().put("schema_version", 2).put("day", day)
            .put("user_id", owner).put("algorithm_version", "per_feature").put("features", features)
            .put("daily", daily).put("nights", JSONArray()).put("sleep_overrides", JSONArray())
            .put("measurements", JSONArray()).put("stale", false).put("compute", compute))
    }
    private fun family(root: JSONObject, key: String) = root.getJSONObject("server_scoring").getJSONObject("compute").getJSONObject("families").getJSONObject(key)
    private fun decode(root: JSONObject) = ServerScoreCacheCodec.parseSnapshot(root.toString(), day, owner)
    private fun available(root: JSONObject, value: Any) {
        family(root, "night_hrv").put("status", "available").put("algorithm_version", "frwhoop-physiology-2")
            .put("canonical_qualification", "signed_reference_approval").put("manifest_hash", "a".repeat(64))
            .put("feature_manifest_hash", "b".repeat(64)).put("result_revision", "sha256:" + "c".repeat(64))
            .put("configuration_version", JSONObject.NULL).put("freshness", "current")
            .getJSONObject("values").put("hrv_rmssd_ms", value)
        family(root, "night_hrv").getJSONObject("details")
            .put("summary", root.getJSONObject("server_scoring").getJSONObject("daily").opt("hrv_summary"))
            .put("heart_rate_windows", root.getJSONObject("server_scoring").getJSONObject("daily").opt("heart_rate_windows"))
        root.getJSONObject("server_scoring").getJSONObject("daily").put("hrv_rmssd_ms", value)
        selectFeature(root, "night_hrv")
    }
    private fun availableMetric(root: JSONObject, familyID: String, metric: String, value: Any) {
        family(root, familyID).put("status", "available").put("reason", JSONObject.NULL)
            .put("algorithm_version", "frwhoop-physiology-2").put("canonical_qualification", "signed_reference_approval")
            .put("manifest_hash", "a".repeat(64)).put("feature_manifest_hash", "b".repeat(64))
            .put("result_revision", "sha256:" + familyID.hashCode().toUInt().toString(16).padStart(64, '0'))
            .put("configuration_version", JSONObject.NULL).put("freshness", "current")
            .getJSONObject("values").put(metric, value)
        val daily = root.getJSONObject("server_scoring").getJSONObject("daily")
        if (familyID == "night_hrv") family(root, familyID).getJSONObject("details")
            .put("summary", daily.opt("hrv_summary")).put("heart_rate_windows", daily.opt("heart_rate_windows"))
        if (familyID == "respiration") family(root, familyID).getJSONObject("details")
            .put("summary", daily.opt("respiration_summary"))
        selectFeature(root, familyID)
    }
    private fun selectFeature(root: JSONObject, familyID: String) {
        val featureID = featureBackedFamilies[familyID] ?: return
        val result = family(root, familyID)
        root.getJSONObject("server_scoring").getJSONObject("features").getJSONObject(featureID)
            .put("status", result.getString("status")).put("reason", result.opt("reason"))
            .put("device_id", result.getString("device_id")).put("algorithm_version", result.getString("algorithm_version"))
            .put("input_revision", result.getLong("input_revision")).put("computed_at", result.getString("computed_at"))
            .put("observed_through", result.opt("observed_through")).put("publication_status", "canonical")
            .put("manifest_hash", result.getString("manifest_hash"))
            .put("feature_manifest_hash", result.getString("feature_manifest_hash"))
            .put("canonical_qualification", result.getString("canonical_qualification"))
    }
    private fun availableSleep(root: JSONObject, topLevelNights: JSONArray, valueNights: Any = topLevelNights,
                               detailNights: Any = topLevelNights) {
        family(root, "sleep").put("status", "available").put("reason", JSONObject.NULL)
            .put("algorithm_version", "frwhoop-physiology-2").put("canonical_qualification", "signed_reference_approval")
            .put("manifest_hash", "a".repeat(64)).put("feature_manifest_hash", "b".repeat(64))
            .put("result_revision", "sha256:" + "d".repeat(64)).put("configuration_version", JSONObject.NULL)
            .put("freshness", "current")
            .getJSONObject("values").put("sleep_sessions", valueNights)
        family(root, "sleep").getJSONObject("details").put("nights", detailNights)
            .put("sleep_overrides", JSONArray(root.getJSONObject("server_scoring").getJSONArray("sleep_overrides").toString()))
        val daily = root.getJSONObject("server_scoring").getJSONObject("daily")
        val dailyCopy = JSONObject(daily.toString())
        family(root, "sleep").getJSONObject("details").put("daily_compatibility", JSONObject().also { compatibility ->
            sleepDailyCompatibilityKeys.forEach { key -> compatibility.put(key, dailyCopy.get(key)) }
        })
        root.getJSONObject("server_scoring").put("nights", topLevelNights)
        selectFeature(root, "sleep")
    }
    private fun hrvMeasurement(value: Double = 40.0) = JSONObject()
        .put("measurement_schema_version", 1).put("feature", "hrv").put("user_id", owner).put("device_id", device)
        .put("start", 1789948800L).put("end", 1789949100L).put("metric", "rmssd").put("unit", "ms")
        .put("input_revision", "8").put("observed_rmssd_ms", value).put("measurement_valid", true)
        .put("reason", JSONObject.NULL).put("context", "quiet_rest").put("baseline_eligible", true)
        .put("source", "whoop5").put("modality", "ppg_prv").put("algorithm_version", "rmssd-5m-v2")
        .put("observed_time_fraction", 1.0)
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
        assertTrue(cache.stale)
        assertNull(cache.computedAt)
    }
    @Test fun zeroNullAndEveryMissingStateNeverUseLocalFallback() {
        val root = body(); available(root, 0)
        var cache = decode(root)
        assertEquals(0.0, ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, false, day, cache, 77.0).value!!, 0.0)
        for (status in listOf("available", "unsupported", "insufficient_input", "insufficient_quality", "unqualified", "processing", "failed", "unavailable", "revoked")) {
            family(root, "night_hrv").put("status", status).getJSONObject("values").put("hrv_rmssd_ms", JSONObject.NULL)
            root.getJSONObject("server_scoring").getJSONObject("daily").put("hrv_rmssd_ms", JSONObject.NULL)
            cache = decode(root)
            val selected = ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, false, day, cache, 77.0)
            assertTrue(selected.fromServer); assertNull(selected.value); assertNotNull(selected.resultRevision)
        }
    }
    @Test fun availableFamilyWithoutCanonicalAuthorizationRejectsTheEnvelope() {
        val root = body(); available(root, 42)
        family(root, "night_hrv").put("canonical_qualification", JSONObject.NULL)
        assertThrows(IllegalArgumentException::class.java) { decode(root) }
        val malformedManifest = body(); available(malformedManifest, 42)
        family(malformedManifest, "night_hrv").put("feature_manifest_hash", "mismatch")
        assertThrows(IllegalArgumentException::class.java) { decode(malformedManifest) }
    }
    @Test fun wrongDeviceOwnerSourceDayOrFabricatedRevisionRejectWholeEnvelope() {
        for ((key, value) in listOf("device_id" to "other", "owner_id" to "other", "source_id" to "other", "window" to "2026-09-20", "result_revision" to "snapshot:9")) {
            val root = body(); family(root, "night_hrv").put(key, value)
            assertThrows(RuntimeException::class.java) { decode(root) }
        }
        val incomplete = body(); incomplete.getJSONObject("server_scoring").getJSONObject("compute").getJSONObject("families").remove("spot_hrv")
        assertThrows(RuntimeException::class.java) { decode(incomplete) }
    }
    @Test fun authorizedFamilyMustMatchSelectedFeatureVersionInputAndManifest() {
        val coherent = body(); available(coherent, 42)
        assertEquals(42.0, decode(coherent).compute!!.families.getValue("night_hrv").number("hrv_rmssd_ms")!!, 0.0)
        val cases = listOf("algorithm_version" to "another-qualified-version", "input_revision" to 9,
            "manifest_hash" to "c".repeat(64), "feature_manifest_hash" to "d".repeat(64),
            "publication_status" to "shadow")
        for ((key, value) in cases) {
            val mismatch = JSONObject(coherent.toString())
            mismatch.getJSONObject("server_scoring").getJSONObject("features").getJSONObject("hrv").put(key, value)
            assertThrows(key, IllegalArgumentException::class.java) { decode(mismatch) }
        }
    }
    @Test fun expiryIsASeparateAdmissionNotAReplayableMeasurement() {
        val root = body(); available(root, 42)
        family(root, "night_hrv").put("decision_id", "decision-a").put("expires_at", "2026-09-22T07:01:30Z")
        val f = decode(root).compute!!.families.getValue("night_hrv")
        assertTrue(f.usableDecision(java.time.Instant.parse("2026-09-22T07:01:00Z").toEpochMilli()))
        assertFalse(f.usableDecision(java.time.Instant.parse("2026-09-22T07:01:30Z").toEpochMilli()))
    }
    @Test fun freshnessCannotAuthorizeValuesOrCompatibilityByItself() {
        for (freshness in listOf("unavailable", "expired")) {
            val root = body(); available(root, 42)
            family(root, "night_hrv").put("freshness", freshness)
            val cache = decode(root)
            assertNull(cache.compute!!.families.getValue("night_hrv").number("hrv_rmssd_ms"))
            assertNull(cache.daily)
            assertTrue(cache.stale)
        }
        val malformed = body(); available(malformed, 42)
        family(malformed, "night_hrv").put("freshness", "fabricated")
        assertThrows(IllegalArgumentException::class.java) { decode(malformed) }
    }
    @Test fun familySchemaRejectsFreshStatusValueDriftAndNonNullMissingness() {
        val fresh = body(); available(fresh, 42)
        family(fresh, "night_hrv").put("status", "fresh")
        assertThrows(IllegalArgumentException::class.java) { decode(fresh) }

        val unavailableValue = body(); available(unavailableValue, 42)
        family(unavailableValue, "night_hrv").put("status", "unqualified")
        assertThrows(IllegalArgumentException::class.java) { decode(unavailableValue) }

        for ((label, mutate) in listOf<Pair<String, (JSONObject) -> Unit>>(
            "extra" to { it.put("invented_metric", 7) },
            "missing" to { it.remove("hrv_sdnn_ms") },
        )) {
            val drifted = body()
            mutate(family(drifted, "night_hrv").getJSONObject("values"))
            assertThrows(label, IllegalArgumentException::class.java) { decode(drifted) }
        }
    }
    @Test fun optionalTimestampTypesAndMaterialScopeAreValidated() {
        for (key in listOf("computed_at", "observed_through", "expires_at")) {
            val malformed = body()
            family(malformed, "night_hrv").put(key, JSONObject().put("not", "a timestamp"))
            assertThrows(key, IllegalArgumentException::class.java) { decode(malformed) }
        }
        for ((label, mutate) in listOf<Pair<String, (JSONObject) -> Unit>>(
            "project" to { it.getJSONObject("server_scoring").getJSONObject("compute").put("project", "ftp://compute.invalid") },
            "source" to { it.getJSONObject("server_scoring").getJSONObject("compute").put("source_id", "not-a-uuid") },
            "device" to { it.getJSONObject("server_scoring").getJSONObject("compute").put("device_id", "not-a-uuid") },
            "day" to { it.getJSONObject("server_scoring").getJSONObject("compute").put("day", "2026-09-20") },
        )) {
            val malformed = body(); mutate(malformed)
            assertThrows(label, RuntimeException::class.java) { decode(malformed) }
        }
        val timezone = body(); family(timezone, "night_hrv").put("timezone_id", "Mars/Olympus_Mons")
        assertThrows(IllegalArgumentException::class.java) { decode(timezone) }

        for (invalidProject in listOf("https://COMPUTE.invalid:443/", "https://user@compute.invalid",
            "https://compute.invalid?tenant=other", "https://compute.invalid/../other")) {
            val malformed = body()
            malformed.getJSONObject("server_scoring").getJSONObject("compute").put("project", invalidProject)
            assertThrows(invalidProject, RuntimeException::class.java) { decode(malformed) }
        }
    }
    @Test fun immutableButWithheldCompatibilityStillRequiresExactTransportBindings() {
        for ((status, freshness) in listOf("available" to "expired", "revoked" to "current")) {
            val scalar = body(); available(scalar, 42)
            family(scalar, "night_hrv").put("status", status).put("freshness", freshness)
            if (status == "revoked") {
                family(scalar, "night_hrv").getJSONObject("values").put("hrv_rmssd_ms", JSONObject.NULL)
                scalar.getJSONObject("server_scoring").getJSONObject("daily").put("hrv_rmssd_ms", JSONObject.NULL)
            }
            val sanitized = decode(scalar)
            assertNull(sanitized.daily)
            assertNull(decode(JSONObject(sanitized.rawSnapshotJSON!!)).daily)
            scalar.getJSONObject("server_scoring").getJSONObject("daily").put("hrv_rmssd_ms", 43)
            assertThrows("$status/$freshness scalar", IllegalArgumentException::class.java) { decode(scalar) }
        }

        val detail = body()
        detail.getJSONObject("server_scoring").getJSONObject("daily")
            .put("hrv_rmssd_ms", 42).put("hrv_summary", JSONObject().put("median", 42))
        availableMetric(detail, "night_hrv", "hrv_rmssd_ms", 42)
        family(detail, "night_hrv").put("freshness", "expired")
        detail.getJSONObject("server_scoring").getJSONObject("daily")
            .put("hrv_summary", JSONObject().put("median", 99))
        assertThrows(IllegalArgumentException::class.java) { decode(detail) }

        val night = JSONObject().put("id", "sleep-a").put("device_id", device).put("user_id", owner)
            .put("algorithm_version", "frwhoop-physiology-2").put("start_at", "2026-09-21T00:00:00Z")
            .put("end_at", "2026-09-21T01:00:00Z")
        val sleep = body()
        val topNights = JSONArray().put(night)
        availableSleep(sleep, topNights, JSONArray(topNights.toString()), JSONArray(topNights.toString()))
        family(sleep, "sleep").put("status", "insufficient_input")
        sleep.getJSONObject("server_scoring").getJSONArray("nights").getJSONObject(0).put("end_at", "2026-09-21T02:00:00Z")
        assertThrows(IllegalArgumentException::class.java) { decode(sleep) }
    }
    @Test fun immutableRevisionRejectsChangedNumbersButNeverBlocksRevocation() {
        val root = body(); available(root, 42)
        val before = decode(root)
        family(root, "night_hrv").getJSONObject("values").put("hrv_rmssd_ms", 55)
        root.getJSONObject("server_scoring").getJSONObject("daily").put("hrv_rmssd_ms", 55)
        assertFalse(ServerComputeRevisionFence.admits(before, decode(root)))
        family(root, "night_hrv").put("status", "revoked").put("input_revision", 1)
            .put("canonical_qualification", JSONObject.NULL).getJSONObject("values").put("hrv_rmssd_ms", JSONObject.NULL)
        val revoked = decode(root)
        assertTrue(ServerComputeRevisionFence.admits(before, revoked))
        assertNull(revoked.compute!!.families.getValue("night_hrv").number("hrv_rmssd_ms"))
        assertEquals(before.compute!!.families.getValue("night_hrv").resultRevision,
            revoked.compute!!.families.getValue("night_hrv").resultRevision)
    }

    @Test fun authorizedSleepBindsTopLevelSessionsToBothImmutableFamilyCopies() {
        val ordered = JSONObject().put("id", "sleep-a").put("device_id", device).put("user_id", owner)
            .put("algorithm_version", "frwhoop-physiology-2").put("start_at", "2026-09-21T00:00:00Z")
            .put("end_at", "2026-09-21T08:00:00Z").put("asleep_min", 0)
            .put("hrv_rmssd_ms", 42).put("resting_hr_bpm", 51).put("resp_rate_bpm", 12)
        val reordered = JSONObject()
        ordered.keys().asSequence().toList().reversed().forEach { reordered.put(it, ordered.get(it)) }
        val coherent = body()
        coherent.getJSONObject("server_scoring").getJSONObject("daily")
            .put("sleep_unstaged_min", 0).put("state_unknown_min", JSONObject.NULL).put("off_body_min", 0)
            .put("opportunity_kind", "estimated_sleep_opportunity").put("full_day_sleep_epochs", JSONArray())
        availableSleep(coherent, JSONArray().put(ordered), JSONArray().put(reordered), JSONArray().put(JSONObject(ordered.toString())))
        val decoded = decode(coherent)
        assertEquals(0.0, decoded.nights.single().asleepMin!!, 0.0)
        assertNull(decoded.nights.single().hrvRmssdMs)
        assertNull(decoded.nights.single().restingHrBpm)
        assertNull(decoded.nights.single().respRateBpm)
        assertEquals(0.0, decoded.daily!!.sleepUnstagedMin!!, 0.0)
        assertNull(decoded.daily!!.stateUnknownMin)
        assertEquals("estimated_sleep_opportunity", decoded.daily!!.opportunityKind)
        assertEquals(decoded.nights, decode(JSONObject(decoded.rawSnapshotJSON!!)).nights)

        val topLevelMutation = JSONObject(coherent.toString())
        topLevelMutation.getJSONObject("server_scoring").getJSONArray("nights").getJSONObject(0).put("asleep_min", 1)
        assertThrows(IllegalArgumentException::class.java) { decode(topLevelMutation) }

        val nestedValueMutation = JSONObject(coherent.toString())
        family(nestedValueMutation, "sleep").getJSONObject("values").getJSONArray("sleep_sessions")
            .getJSONObject(0).put("asleep_min", 2)
        assertThrows(IllegalArgumentException::class.java) { decode(nestedValueMutation) }

        val nestedDetailMutation = JSONObject(coherent.toString())
        family(nestedDetailMutation, "sleep").getJSONObject("details").getJSONArray("nights")
            .getJSONObject(0).put("asleep_min", 3)
        assertThrows(IllegalArgumentException::class.java) { decode(nestedDetailMutation) }

        val dailyCompatibilityMutation = JSONObject(coherent.toString())
        dailyCompatibilityMutation.getJSONObject("server_scoring").getJSONObject("daily").put("sleep_unstaged_min", 1)
        assertThrows(IllegalArgumentException::class.java) { decode(dailyCompatibilityMutation) }

        val override = JSONObject().put("id", "44444444-4444-4444-8444-444444444444").put("device_id", device)
        val overrideEnvelope = body()
        overrideEnvelope.getJSONObject("server_scoring").put("sleep_overrides", JSONArray().put(override))
        availableSleep(overrideEnvelope, JSONArray())
        assertEquals(override.toString(), JSONObject(decode(overrideEnvelope).rawSnapshotJSON!!)
            .getJSONObject("server_scoring").getJSONArray("sleep_overrides").getJSONObject(0).toString())
        val overrideMutation = JSONObject(overrideEnvelope.toString())
        overrideMutation.getJSONObject("server_scoring").getJSONArray("sleep_overrides")
            .getJSONObject(0).put("device_id", "another-device")
        assertThrows(IllegalArgumentException::class.java) { decode(overrideMutation) }

        val empty = body(); availableSleep(empty, JSONArray(), JSONArray(), JSONArray())
        assertTrue(decode(empty).nights.isEmpty())
        for (missing in listOf(JSONObject.NULL, JSONArray())) {
            val explicitMissing = body(); availableSleep(explicitMissing, JSONArray(), missing, JSONArray())
            if (missing === JSONObject.NULL) assertThrows(IllegalArgumentException::class.java) { decode(explicitMissing) }
            else assertTrue(decode(explicitMissing).nights.isEmpty())
        }
        val missingTopLevel = body(); availableSleep(missingTopLevel, JSONArray(), JSONArray(), JSONArray())
        missingTopLevel.getJSONObject("server_scoring").remove("nights")
        assertThrows(IllegalArgumentException::class.java) { decode(missingTopLevel) }
    }

    @Test fun authorizedOwnedScalarsBindTopLevelDailyToImmutableFamilyValues() {
        data class Binding(val family: String, val metric: String, val top: Any = 0, val immutable: Any = top)
        val bindings = listOf(
            Binding("night_hrv", "hrv_rmssd_ms"), Binding("night_hrv", "hrv_sdnn_ms", JSONObject.NULL),
            Binding("night_hrv", "resting_hr_bpm"), Binding("sleep", "sleep_total_min"),
            Binding("sleep", "sleep_in_bed_min"), Binding("sleep", "sleep_awake_min"),
            Binding("sleep", "sleep_light_min"), Binding("sleep", "sleep_deep_min"),
            Binding("sleep", "sleep_rem_min"), Binding("sleep", "sleep_efficiency", 0.5, 50),
            Binding("sleep", "disturbances"), Binding("respiration", "resp_rate_bpm"),
            Binding("recovery", "recovery"), Binding("strain_energy", "strain"),
            Binding("oxygen", "spo2_pct"), Binding("temperature", "skin_temp_c"),
            Binding("temperature", "skin_temp_dev_c"),
        )
        val coherent = body()
        val daily = coherent.getJSONObject("server_scoring").getJSONObject("daily")
        bindings.forEach { binding ->
            availableMetric(coherent, binding.family, binding.metric, binding.immutable)
            daily.put(binding.metric, binding.top)
        }
        availableSleep(coherent, JSONArray(), JSONArray(), JSONArray())
        val cache = decode(coherent)
        assertEquals(0.0, ServerConsumerProjection.number(cache, "hrv_rmssd_ms")!!, 0.0)
        assertNull(ServerConsumerProjection.number(cache, "hrv_sdnn_ms"))
        assertEquals(50.0, ServerConsumerProjection.number(cache, "sleep_efficiency")!!, 0.0)
        assertEquals(0.0, cache.daily!!.hrvRmssdMs!!, 0.0)
        assertNull(cache.daily!!.rest)
        assertEquals(0.5, cache.daily!!.sleepEfficiency!!, 0.0)
        for (binding in bindings) {
            val mutated = JSONObject(coherent.toString())
            mutated.getJSONObject("server_scoring").getJSONObject("daily").put(binding.metric, 1)
            assertThrows(binding.metric, IllegalArgumentException::class.java) { decode(mutated) }
        }
        val omitted = JSONObject(coherent.toString())
        omitted.getJSONObject("server_scoring").getJSONObject("daily").remove("resting_hr_bpm")
        assertThrows(IllegalArgumentException::class.java) { decode(omitted) }
    }

    @Test fun unqualifiedTopLevelScalarCannotReachCanonicalProjection() {
        val root = body()
        root.getJSONObject("server_scoring").getJSONObject("daily").put("skin_temp_c", 34.5).put("skin_temp_dev_c", 0.0)
            .put("sleep_unstaged_min", 5).put("state_unknown_min", 0).put("off_body_min", 0)
            .put("opportunity_kind", "estimated_sleep_opportunity").put("full_day_sleep_epochs", JSONArray())
        root.getJSONObject("server_scoring").put("nights", JSONArray().put(JSONObject()
            .put("id", "unauthorized-sleep").put("device_id", device)
            .put("start_at", "2026-09-21T00:00:00Z").put("end_at", "2026-09-21T01:00:00Z")))
            .put("sleep_overrides", JSONArray().put(JSONObject().put("id", "unauthorized-override")))
            .put("measurements", JSONArray().put(hrvMeasurement()))
        val cache = decode(root)
        assertNull(ServerConsumerProjection.number(cache, "skin_temp_c"))
        assertNull(ServerConsumerProjection.number(cache, "skin_temp_dev_c"))
        assertNull(cache.daily)
        assertTrue(cache.nights.isEmpty())
        val sanitized = JSONObject(cache.rawSnapshotJSON!!).getJSONObject("server_scoring")
        assertTrue(sanitized.isNull("daily"))
        assertEquals(0, sanitized.getJSONArray("nights").length())
        assertEquals(0, sanitized.getJSONArray("sleep_overrides").length())
        assertEquals(0, sanitized.getJSONArray("measurements").length())
    }

    @Test fun summaryCompatibilityMustMatchItsAuthorizedFamilyAndSurvivesSanitizedReload() {
        val coherent = body()
        val daily = coherent.getJSONObject("server_scoring").getJSONObject("daily")
        daily.put("hrv_rmssd_ms", 42).put("hrv_summary", JSONObject().put("median", 42))
            .put("heart_rate_windows", JSONArray().put(JSONObject().put("value", 42)))
            .put("resp_rate_bpm", 14).put("respiration_summary", JSONObject().put("median_bpm", 14))
        availableMetric(coherent, "night_hrv", "hrv_rmssd_ms", 42)
        availableMetric(coherent, "respiration", "resp_rate_bpm", 14)
        val cache = decode(coherent)
        val sanitized = JSONObject(cache.rawSnapshotJSON!!).getJSONObject("server_scoring").getJSONObject("daily")
        assertEquals(42, sanitized.getJSONObject("hrv_summary").getInt("median"))
        assertEquals(14, sanitized.getJSONObject("respiration_summary").getInt("median_bpm"))
        assertEquals(family(coherent, "respiration").getString("result_revision"),
            ServerRespirationSummary.project(cache, day)!!.resultRevision)
        assertEquals(cache.daily, decode(JSONObject(cache.rawSnapshotJSON!!)).daily)
        for (key in listOf("hrv_summary", "heart_rate_windows", "respiration_summary")) {
            val mutated = JSONObject(coherent.toString())
            mutated.getJSONObject("server_scoring").getJSONObject("daily").put(key, JSONObject().put("mutated", true))
            assertThrows(key, IllegalArgumentException::class.java) { decode(mutated) }
        }
    }

    @Test fun currentHrvMeasurementsUseCurrentFamilyIdentityEvenWhenQualityIsInsufficient() {
        val coherent = body()
        val row = hrvMeasurement(0.0)
        coherent.getJSONObject("server_scoring").put("measurements", JSONArray().put(row))
        val current = family(coherent, "current_hrv").put("status", "insufficient_quality")
            .put("reason", "qualified_closed_window_required").put("algorithm_version", "frwhoop-physiology-2")
            .put("canonical_qualification", "signed_reference_approval").put("manifest_hash", "a".repeat(64))
            .put("feature_manifest_hash", "b".repeat(64)).put("result_revision", "sha256:" + "e".repeat(64))
            .put("configuration_version", JSONObject.NULL).put("freshness", "current")
        current.getJSONObject("details").put("measurements", JSONArray().put(JSONObject(row.toString())))
        selectFeature(coherent, "current_hrv")
        coherent.getJSONObject("server_scoring").getJSONObject("features").getJSONObject("hrv").put("status", "available")
        val cache = decode(coherent)
        val series = ServerHrvSeries.from(cache, day)
        assertEquals("sha256:" + "e".repeat(64), series.resultRevision)
        assertEquals(1, series.windows.size)
        assertEquals(0.0, series.windows.single().rmssdMs!!, 0.0)
        assertEquals(series.windows, ServerHrvSeries.from(decode(JSONObject(cache.rawSnapshotJSON!!)), day).windows)

        val mutated = JSONObject(coherent.toString())
        mutated.getJSONObject("server_scoring").getJSONArray("measurements").getJSONObject(0)
            .put("observed_rmssd_ms", 99)
        assertThrows(IllegalArgumentException::class.java) { decode(mutated) }

        val wrongIdentity = JSONObject(coherent.toString())
        wrongIdentity.getJSONObject("server_scoring").getJSONObject("features").getJSONObject("hrv")
            .put("input_revision", 9)
        assertThrows(IllegalArgumentException::class.java) { decode(wrongIdentity) }

        val unavailableFreshness = JSONObject(coherent.toString())
        family(unavailableFreshness, "current_hrv").put("freshness", "unavailable")
        val withheld = decode(unavailableFreshness)
        val withheldSeries = ServerHrvSeries.from(withheld, day)
        assertTrue(withheldSeries.windows.isEmpty())
        assertNull(withheldSeries.resultRevision)
        assertEquals(0, JSONObject(withheld.rawSnapshotJSON!!).getJSONObject("server_scoring")
            .getJSONArray("measurements").length())

        for ((label, mutate) in listOf<Pair<String, (JSONObject) -> Unit>>(
            "expired" to { it.put("freshness", "expired") },
            "expired_at" to { it.put("expires_at", "1970-01-01T00:00:00Z") },
            "failed" to { it.put("status", "failed") },
        )) {
            val unavailable = JSONObject(coherent.toString())
            mutate(family(unavailable, "current_hrv"))
            val unavailableSeries = ServerHrvSeries.from(decode(unavailable), day)
            assertTrue(label, unavailableSeries.windows.isEmpty())
            assertNull(label, unavailableSeries.resultRevision)
        }

        val unqualified = body()
        unqualified.getJSONObject("server_scoring").put("measurements", JSONArray().put(row))
        val cleared = decode(unqualified)
        assertTrue(ServerHrvSeries.from(cleared, day).windows.isEmpty())
        assertEquals(0, JSONObject(cleared.rawSnapshotJSON!!).getJSONObject("server_scoring")
            .getJSONArray("measurements").length())
    }

    @Test fun registrationPendingPersistsOwnershipAndEvictsAvailableDeviceResult() {
        val root = body(); available(root, 42)
        val before = decode(root)
        root.getJSONObject("server_scoring").getJSONObject("compute").put("device_id", JSONObject.NULL)
        ServerComputeContract.familyIDs.forEach { key ->
            family(root, key).put("device_id", JSONObject.NULL).put("result_revision", JSONObject.NULL)
                .put("status", "unavailable").put("reason", "device_registration_pending")
                .put("input_revision", JSONObject.NULL).put("canonical_qualification", JSONObject.NULL)
            val values = family(root, key).getJSONObject("values")
            values.keys().asSequence().toList().forEach { metric -> values.put(metric, JSONObject.NULL) }
        }
        val pending = decode(root)
        assertTrue(pending.stale)
        assertNull(pending.computedAt)
        assertNull(pending.daily)
        assertTrue(ServerComputeRevisionFence.admits(before, pending))
        assertTrue(ServerComputeRevisionFence.admits(pending, before))
        assertTrue(pending.compute!!.families.values.none { it.authorized })
        val ownership = ServerMetricOwnership(project, owner, device).observe(pending)
        val restored = ServerMetricOwnership.restore(ownership.encode(), project, owner, device)
        assertEquals(ServerComputeContract.metricIDs, restored.metrics)
        assertEquals(pending.compute, restored.presentation(pending, day)!!.compute)
        assertNull(ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV, false, day,
            restored.presentation(pending, day), 77.0).value)
        val session = ServerScoreSessionState().apply { activate(owner) }
        assertTrue(session.accept(before, session.generation(), owner))
        assertTrue(session.accept(pending, session.generation(), owner))
    }
    private fun oldLegacyBody(marker: JSONObject? = null): JSONObject {
        val root = body()
        available(root, 42)
        family(root, "night_hrv").getJSONObject("values").put("resting_hr_bpm", 51)
        val overlay = root.getJSONObject("server_scoring")
        val daily = overlay.getJSONObject("daily").put("resting_hr_bpm", 51)
        val night = JSONObject().put("id", "legacy-night").put("device_id", device).put("user_id", owner)
            .put("algorithm_version", "frwhoop-server-1").put("start_at", "2026-09-21T00:00:00Z")
            .put("end_at", "2026-09-21T08:00:00Z").put("in_bed_min", 480).put("asleep_min", 450)
            .put("hrv_rmssd_ms", 42).put("hrv_sdnn_ms", 52).put("resting_hr_bpm", 51)
            .put("resp_rate_bpm", 12).put("recovery", 77).put("efficiency", 0.9375)
            .put("stages", JSONArray().put(JSONObject().put("start", 1789948800L)
                .put("end", 1789977600L).put("stage", "deep")))
        availableSleep(root, JSONArray().put(night))
        family(root, "sleep").getJSONObject("values").put("sleep_total_min", 450).put("sleep_in_bed_min", 480)
        daily.put("sleep_total_min", 450).put("sleep_in_bed_min", 480)
        availableMetric(root, "respiration", "resp_rate_bpm", 12); daily.put("resp_rate_bpm", 12)
        availableMetric(root, "recovery", "recovery", 77); daily.put("recovery", 77)
        for (key in listOf("night_hrv", "sleep", "respiration", "recovery")) {
            family(root, key).put("algorithm_version", "frwhoop-server-1")
                .put("canonical_qualification", "retained_legacy").put("feature_manifest_hash", JSONObject.NULL)
            if (marker != null) family(root, key).getJSONObject("details").put("input_eligibility", JSONObject(marker.toString()))
        }
        for (key in listOf("hrv", "sleep", "respiration")) overlay.getJSONObject("features").getJSONObject(key)
            .put("algorithm_version", "frwhoop-server-1").put("canonical_qualification", "retained_legacy")
            .put("feature_manifest_hash", JSONObject.NULL)
            .apply { if (marker != null) put("input_eligibility", JSONObject(marker.toString())) }
        return root
    }

    @Test fun offlineOldLegacyBytesLoseBeatDependentValuesButKeepScopedScalarResult() {
        val bytes = oldLegacyBody().toString()
        val disk = java.io.File.createTempFile("old-legacy-cache", ".json")
        try {
            disk.writeText(bytes)
            val cache = decode(JSONObject(disk.readText()))
            assertNull(ServerConsumerProjection.number(cache, "hrv_rmssd_ms"))
            assertNull(ServerConsumerProjection.number(cache, "resp_rate_bpm"))
            assertNull(ServerConsumerProjection.number(cache, "recovery"))
            assertNull(ServerConsumerProjection.number(cache, "sleep_total_min"))
            assertEquals(51.0, ServerConsumerProjection.number(cache, "resting_hr_bpm")!!, 0.0)
            assertEquals(480.0, ServerConsumerProjection.number(cache, "sleep_in_bed_min")!!, 0.0)
            assertNull(cache.nights.single().hrvRmssdMs); assertNull(cache.nights.single().asleepMin)
            assertTrue(cache.nights.single().stages.isEmpty())
            assertEquals("2026-09-21T00:00:00Z", cache.nights.single().startAt)
            assertEquals(cache.compute, decode(JSONObject(cache.rawSnapshotJSON!!)).compute)
            assertEquals(bytes, disk.readText()) // read policy never rewrites the immutable old cache fixture
        } finally { disk.delete() }
    }

    @Test fun exactExcludedMarkerPreservesSleepButNeverQualifiesBeatMetrics() {
        val marker = JSONObject().put("policy_version", "legacy-rr-excluded-1").put("rr_input", "excluded")
        val cache = decode(oldLegacyBody(marker))
        assertEquals(450.0, ServerConsumerProjection.number(cache, "sleep_total_min")!!, 0.0)
        assertEquals(51.0, ServerConsumerProjection.number(cache, "resting_hr_bpm")!!, 0.0)
        assertNull(ServerConsumerProjection.number(cache, "hrv_rmssd_ms"))
        assertNull(ServerConsumerProjection.number(cache, "resp_rate_bpm"))
        assertNull(ServerConsumerProjection.number(cache, "recovery"))
        assertTrue(cache.nights.single().stages.isNotEmpty())
        marker.put("qualification", "fabricated")
        assertNull(ServerConsumerProjection.number(decode(oldLegacyBody(marker)), "sleep_total_min"))
    }

    @Test fun sameHashLegacyRefreshNormalizesOnlyIneligibleMetricsAndPreservesIdentityFence() {
        val raw = oldLegacyBody()
        val safe = decode(JSONObject(raw.toString()))
        val oldFamilies = safe.compute!!.families.mapValues { (key, value) ->
            val old = family(raw, key)
            value.copy(status = old.getString("status"), reason = old.opt("reason") as? String, json = old.toString())
        }
        val old = safe.copy(compute = safe.compute!!.copy(families = oldFamilies))
        assertNull(old.compute!!.families.getValue("night_hrv").number("hrv_rmssd_ms"))
        val oldNight = (old.compute!!.families.getValue("sleep").value("sleep_sessions") as JSONArray).getJSONObject(0)
        assertTrue(oldNight.isNull("hrv_rmssd_ms")); assertTrue(oldNight.isNull("asleep_min"))
        assertEquals(0, oldNight.getJSONArray("stages").length())
        assertEquals(51, oldNight.getInt("resting_hr_bpm"))
        val spotJSON = JSONObject(old.compute!!.families.getValue("night_hrv").json)
            .put("metrics", JSONArray(listOf("spot_hrv_rmssd_ms")))
            .put("values", JSONObject().put("spot_hrv_rmssd_ms", 42))
            .put("decision_id", "old-spot-decision").put("expires_at", "2099-01-01T00:00:00Z")
        val spot = old.compute!!.families.getValue("night_hrv").copy(family = "spot_hrv",
            metrics = setOf("spot_hrv_rmssd_ms"), decisionId = "old-spot-decision",
            expiresAt = "2099-01-01T00:00:00Z", json = spotJSON.toString())
        assertTrue(spot.authorized)
        assertFalse(spot.usableDecision(System.currentTimeMillis()))
        assertTrue(ServerComputeRevisionFence.admits(old, safe))
        assertEquals("beat_timing_unverified", ServerVitalSelection.resolve(ServerVitalSelection.Metric.HRV,
            true, day, old, 99.0).status)
        val changed = oldLegacyBody()
        family(changed, "night_hrv").getJSONObject("values").put("resting_hr_bpm", 52)
        changed.getJSONObject("server_scoring").getJSONObject("daily").put("resting_hr_bpm", 52)
        assertFalse(ServerComputeRevisionFence.admits(safe, decode(changed)))
        val changedMarker = JSONObject().put("policy_version", "legacy-rr-excluded-1").put("rr_input", "excluded")
        assertFalse(ServerComputeRevisionFence.admits(safe, decode(oldLegacyBody(changedMarker))))
    }

    @Test fun legacyReadGateDoesNotNormalizeMalformedAuthorizationOrRevocationIntoAvailability() {
        for (key in listOf("canonical_qualification", "manifest_hash")) {
            val raw = oldLegacyBody()
            family(raw, "night_hrv").put(key, JSONObject.NULL)
            assertThrows(IllegalArgumentException::class.java) { decode(raw) }
        }
        val revoked = oldLegacyBody()
        val f = family(revoked, "night_hrv").put("status", "revoked").put("reason", "approval_revoked")
        f.getJSONObject("values").keys().asSequence().toList().forEach { f.getJSONObject("values").put(it, JSONObject.NULL) }
        val daily = revoked.getJSONObject("server_scoring").getJSONObject("daily")
        for (key in listOf("hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm")) daily.put(key, JSONObject.NULL)
        assertEquals("approval_revoked", decode(revoked).compute!!.families.getValue("night_hrv").reason)
    }

}
