package com.noop.push

import org.json.JSONArray
import org.json.JSONObject

/** The production decoder is independent of networking and Android lifecycle state. */
object ServerScoreCacheCodec {
    fun parseSnapshot(body: String, day: String, ownerId: String, fetchedAtMs: Long = System.currentTimeMillis()): ServerScoreDayCache {
        val root = JSONObject(body)
        val o = root.getJSONObject("server_scoring")
        val projectionState = o.opt("compatibility_projection")
        require(projectionState == null || projectionState == canonicalProjectionState) { "invalid compatibility projection state" }
        val sanitizedInput = projectionState == canonicalProjectionState
        require(ownerId.isNotBlank() && o.optInt("schema_version") == 2 &&
            o.optString("user_id").lowercase() == ownerId.lowercase() && o.optString("day") == day) { "invalid score scope" }
        val rawFeatures = o.getJSONObject("features")
        require(rawFeatures.length() > 0) { "missing source selection" }
        val features = rawFeatures.keys().asSequence().associateWith { key ->
            val f = rawFeatures.getJSONObject(key)
            val status = f.optString("status", "unavailable")
            val device = f.str("device_id"); val version = f.str("algorithm_version")
            require(status == "unavailable" || (!device.isNullOrBlank() && !version.isNullOrBlank())) { "invalid source selection" }
            ServerScoreFeatureCache(status, f.str("reason"), device, version, f.long("input_revision"), f.long("required_revision"),
                f.str("computed_at"), f.str("observed_through"), f.str("publication_status"), f.str("archive_status"), f.str("manifest_hash"),
                f.bool("supports_boundary_overrides"), f.str("processing_status"), f.str("timezone_id"),
                f.optJSONArray("timezone_ids")?.let { a -> (0 until a.length()).mapNotNull { a.opt(it) as? String } },
                f.str("canonical_qualification"), f.str("feature_manifest_hash"))
        }
        val rawDaily = o.optJSONObject("daily")
        val legacyDaily = rawDaily?.let(::decodeDaily)
        val compute = ServerComputeContract.decode(o.optJSONObject("compute") ?: root.optJSONObject("compute"), ownerId, day)
        for ((familyID, featureID) in featureBackedFamilies) {
            val family = compute?.families?.get(familyID)?.takeIf { it.hasImmutableIdentity } ?: continue
            val selected = features[featureID]
            require(selected != null && selected.isCanonicalAvailable &&
                selected.deviceId == family.deviceId && selected.algorithmVersion == family.algorithmVersion &&
                selected.inputRevision == family.inputRevision && selected.manifestHash == family.manifestHash &&
                selected.featureManifestHash == family.featureManifestHash &&
                selected.canonicalQualification == family.canonicalQualification &&
                selected.computedAt == family.computedAt && selected.observedThrough == family.observedThrough) {
                "$familyID selected feature identity mismatch"
            }
        }
        val sanitizedDaily = JSONObject()
        var hasDailyProjection = false
        for (binding in scalarBindings) {
            val family = compute?.families?.get(binding.family)?.takeIf { it.hasImmutableIdentity } ?: continue
            val values = JSONObject(family.json).optJSONObject("values")
            require(values?.has(binding.metric) == true) { "${binding.metric} immutable result missing" }
            if (!sanitizedInput || family.publishable()) {
                require(rawDaily != null && rawDaily.has(binding.metric) &&
                    scalarMatches(rawDaily.opt(binding.metric), values.opt(binding.metric), binding.scale)) {
                    "${binding.metric} result identity mismatch"
                }
            }
            if (!family.publishable()) continue
            sanitizedDaily.put(binding.metric, projectedScalar(values.opt(binding.metric), binding.scale))
            hasDailyProjection = true
        }
        for (binding in detailBindings) {
            val family = compute?.families?.get(binding.family)?.takeIf { it.hasImmutableIdentity } ?: continue
            val details = JSONObject(family.json).optJSONObject("details")
            require(details?.has(binding.detail) == true) { "${binding.topLevel} immutable result missing" }
            if (!sanitizedInput || family.publishable()) {
                require(rawDaily != null && rawDaily.has(binding.topLevel) &&
                    canonical(rawDaily.opt(binding.topLevel)) == canonical(details.opt(binding.detail))) {
                    "${binding.topLevel} result identity mismatch"
                }
            }
            if (!family.publishable()) continue
            sanitizedDaily.put(binding.topLevel, copyJSON(details.opt(binding.detail)))
            hasDailyProjection = true
        }
        val sleep = features["sleep"]
        val nestedHrv = features["hrv"]?.matchesCanonicalSnapshot(sleep) == true
        val nestedRespiration = features["respiration"]?.matchesCanonicalSnapshot(sleep) == true
        val publishNestedHrv = compute?.families?.get("night_hrv")?.publishable() ?: nestedHrv
        val publishNestedRespiration = compute?.families?.get("respiration")?.publishable() ?: nestedRespiration
        val rawNights = o.opt("nights")
        val nightArray = rawNights as? JSONArray ?: JSONArray()
        val sleepFamily = compute?.families?.get("sleep")
        val publishSleep = sleepFamily?.publishable() == true
        var projectedSleepOverrides = JSONArray()
        sleepFamily?.takeIf { it.hasImmutableIdentity }?.let { family ->
            val immutable = JSONObject(family.json)
            val valueSessions = immutable.optJSONObject("values")?.opt("sleep_sessions")
            val details = immutable.optJSONObject("details")
            val detailNights = details?.opt("nights")
            val rawOverrides = o.opt("sleep_overrides")
            val detailOverrides = details?.opt("sleep_overrides")
            val compatibility = details?.optJSONObject("daily_compatibility")
            require(valueSessions is JSONArray && detailNights is JSONArray && detailOverrides is JSONArray &&
                canonical(valueSessions) == canonical(detailNights)) { "sleep immutable result identity mismatch" }
            require(compatibility != null &&
                compatibility.keys().asSequence().toSet() == sleepDailyCompatibilityKeys &&
                sleepDailyCompatibilityKeys.all(compatibility::has)) { "sleep daily compatibility contract mismatch" }
            if (!sanitizedInput || publishSleep) {
                require(rawNights is JSONArray &&
                    (canonical(rawNights) == canonical(valueSessions) || sanitizedInput &&
                        canonical(rawNights) == canonical(sanitizeNightCompatibility(valueSessions,
                            nestedHrv && publishNestedHrv, nestedRespiration && publishNestedRespiration)))) {
                    "sleep result identity mismatch"
                }
                require(rawOverrides is JSONArray && canonical(rawOverrides) == canonical(detailOverrides)) {
                    "sleep override result identity mismatch"
                }
                require(rawDaily != null && sleepDailyCompatibilityKeys.all { key ->
                    rawDaily.has(key) && canonical(rawDaily.opt(key)) == canonical(compatibility.opt(key))
                }) { "sleep daily compatibility mismatch" }
            }
            if (!publishSleep) return@let
            sleepDailyCompatibilityKeys.forEach { key -> sanitizedDaily.put(key, copyJSON(compatibility.opt(key))) }
            hasDailyProjection = true
            projectedSleepOverrides = JSONArray(detailOverrides.toString())
        }
        if (sleepFamily != null && !sleepFamily.hasImmutableIdentity)
            require(!JSONObject(sleepFamily.json).optJSONObject("details").orEmpty().has("daily_compatibility")) {
                "unauthorized sleep daily compatibility"
            }
        val publishNights = compute == null || publishSleep
        val sanitizedNights = JSONArray()
        val nights = if (!publishNights) emptyList() else nightArray.objects().map { rawNight ->
            // Legacy decoding historically strips unauthorized compatibility fields from the retained raw
            // snapshot. A final-hosted snapshot must remain byte-semantically equal to its immutable family,
            // so sanitize a detached object and publish only the typed view.
            val n = if (compute == null) rawNight else JSONObject(rawNight.toString())
            val device = n.str("device_id")
            require(sleep?.deviceId == null || device == sleep.deviceId) { "night device scope mismatch" }
            require(n.str("user_id") == null || n.str("user_id").equals(ownerId, ignoreCase = true)) { "night owner scope mismatch" }
            val sourceVersion = n.str("algorithm_version") ?: sleep?.algorithmVersion
            require(sleep?.algorithmVersion == null || sourceVersion == sleep.algorithmVersion) { "night algorithm scope mismatch" }
            stripNightCompatibility(n, nestedHrv && publishNestedHrv, nestedRespiration && publishNestedRespiration)
            if (compute != null) sanitizedNights.put(JSONObject(n.toString()))
            val legacy = sourceVersion == "frwhoop-server-1"
            val stages = (n.optJSONArray("stages") ?: n.optJSONArray("hypnogram") ?: JSONArray()).objects().map { s ->
                val lo = s.num("start") ?: error("missing epoch start")
                val hi = s.num("end") ?: error("missing epoch end")
                require(hi > lo && lo >= -62135596800.0 && hi <= 253402300799.0) { "invalid epoch span" }
                val stage = s.str("stage") ?: "unknown"
                val stageLegacy = legacy && (s.str("algorithm_version") ?: sourceVersion) == "frwhoop-server-1"
                val legacyState = when (stage) { "light", "deep", "rem" -> "sleep"; "wake", "awake" -> "awake"; else -> "state_unknown" }
                ServerScoreStageCache(lo.toLong(), hi.toLong(), stage, s.str("state") ?: if (stageLegacy) legacyState else "state_unknown",
                    s.num("p_sleep"), s.num("p_wake"), s.num("p_light"), s.num("p_deep"), s.num("p_rem"),
                    s.num("evidence_coverage"), s.str("reason") ?: if (stageLegacy) "legacy_quality_unavailable" else null,
                    s.str("calibration_status") ?: if (stageLegacy) "legacy_unvalidated" else null,
                    s.str("algorithm_version") ?: if (stageLegacy) sourceVersion else null, s.str("computation_mode"))
            }
            ServerScoreNightCache(id = n.getString("id").also { require(it.isNotBlank()) }, startAt = n.getString("start_at"),
                endAt = n.getString("end_at"), isNap = n.optBoolean("is_nap"), asleepMin = n.num("asleep_min"),
                inBedMin = n.num("in_bed_min"), lightMin = n.num("light_min"), deepMin = n.num("deep_min"),
                remMin = n.num("rem_min"), awakeMin = n.num("awake_min"), efficiency = n.num("efficiency"),
                hrvRmssdMs = n.num("hrv_rmssd_ms"), restingHrBpm = n.num("resting_hr_bpm")?.toInt(), stages = stages,
                deviceId = device, episodeType = n.str("episode_type") ?: if (legacy) (if (n.optBoolean("is_nap")) "nap" else "main_sleep") else null,
                mainSleepGroupId = n.str("main_sleep_group_id"), boundaryProvenance = n.str("boundary_provenance"), opportunityKind = n.str("opportunity_kind"),
                startTimezoneId = n.str("start_timezone_id"), endTimezoneId = n.str("end_timezone_id"),
                measurementAvailable = n.bool("measurement_available") ?: if (legacy) n.num("asleep_min")?.let { it >= 0 } else null,
                sleepUnstagedMin = n.num("sleep_unstaged_min"), stateUnknownMin = n.num("state_unknown_min"),
                offBodyMin = n.num("off_body_min"), stateCoverage = n.num("state_coverage"), manualEdit = n.bool("manual_edit"),
                respRateBpm = n.num("resp_rate_bpm"))
        }
        val currentHrv = compute?.families?.get("current_hrv")
        val publishMeasurements = currentHrv?.currentHrvPublishable() == true
        val projectedMeasurements = if (currentHrv?.hasImmutableIdentity == true) {
            val details = JSONObject(currentHrv!!.json).optJSONObject("details")
            val expected = details?.opt("measurements") as? JSONArray
            require(expected != null) { "current HRV measurement identity missing" }
            if (!sanitizedInput || publishMeasurements) {
                val rawMeasurements = o.opt("measurements") as? JSONArray
                require(rawMeasurements != null) { "current HRV measurement identity missing" }
                val rawHrv = JSONArray()
                for (index in 0 until rawMeasurements.length()) {
                    val row = rawMeasurements.opt(index)
                    if (row is JSONObject && row.optString("feature") == "hrv") rawHrv.put(JSONObject(row.toString()))
                }
                require(canonical(rawHrv) == canonical(expected)) { "current HRV measurement identity mismatch" }
            }
            if (publishMeasurements) JSONArray(expected.toString()) else JSONArray()
        } else JSONArray()
        val admittedFamilies = compute?.families?.values?.filter { it.admittedForCompatibility() }.orEmpty()
        val canonicalComputedAt = admittedFamilies.mapNotNull { family ->
            family.computedAt?.let { value -> runCatching { value to java.time.Instant.parse(value) }.getOrNull() }
        }.maxByOrNull { it.second }?.first
        val canonicalStale = admittedFamilies.isEmpty() || admittedFamilies.any { it.status == "stale" || it.freshness == "stale" }
        val snapshotRoot = if (compute == null) root else JSONObject(root.toString()).also { sanitizedRoot ->
            val sanitized = sanitizedRoot.getJSONObject("server_scoring")
            if (hasDailyProjection) {
                val canonicalDevice = compute.families.values.mapNotNull { it.deviceId }.distinct().singleOrNull()
                sanitizedDaily.put("day", day).put("source_device_id", canonicalDevice ?: JSONObject.NULL)
                    .put("computed_at", canonicalComputedAt ?: JSONObject.NULL)
                sanitized.put("daily", sanitizedDaily)
            } else sanitized.put("daily", JSONObject.NULL)
            sanitized.put("nights", if (publishSleep) sanitizedNights else JSONArray())
                .put("sleep_overrides", if (publishSleep) projectedSleepOverrides else JSONArray())
                .put("measurements", projectedMeasurements)
                .put("computed_at", canonicalComputedAt ?: JSONObject.NULL)
                .put("stale", canonicalStale)
                .put("compatibility_projection", canonicalProjectionState)
        }
        val snapshotOverlay = snapshotRoot.getJSONObject("server_scoring")
        if (sanitizedInput) for (key in canonicalProjectionKeys) {
            require(o.has(key) && canonical(o.opt(key)) == canonical(snapshotOverlay.opt(key))) {
                "$key sanitized compatibility mismatch"
            }
        }
        val daily = if (compute == null) legacyDaily else snapshotOverlay.optJSONObject("daily")?.let(::decodeDaily)
        return ServerScoreDayCache(day, o.getString("algorithm_version"), daily, nights, snapshotOverlay.str("computed_at"),
            snapshotOverlay.optBoolean("stale", true), fetchedAtMs, ownerId.lowercase(), 2, features, snapshotRoot.toString(),
            ownedMetrics = compute?.ownedMetrics, compute = compute)
    }

    private fun JSONObject.str(key: String) = (opt(key) as? String)?.takeIf { it.isNotBlank() }
    private fun JSONObject.num(key: String) = (opt(key) as? Number)?.toDouble()?.takeIf { it.isFinite() }
    private fun JSONObject.long(key: String) = (opt(key) as? Number)?.let { number -> number.toLong().also {
        require(number.toDouble().isFinite() && number.toDouble() == it.toDouble()) { "invalid integer identity" }
    } }
    private fun JSONObject.bool(key: String) = opt(key) as? Boolean
    private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
    private data class ScalarBinding(val family: String, val metric: String, val scale: Int = 1)
    private data class DetailBinding(val family: String, val topLevel: String, val detail: String)
    private val featureBackedFamilies = mapOf("night_hrv" to "hrv", "current_hrv" to "hrv", "sleep" to "sleep",
        "respiration" to "respiration", "recovery" to "hrv", "strain_energy" to "hrv", "oxygen" to "hrv",
        "temperature" to "hrv")
    private val scalarBindings = listOf(
        ScalarBinding("night_hrv", "hrv_rmssd_ms"), ScalarBinding("night_hrv", "hrv_sdnn_ms"),
        ScalarBinding("night_hrv", "resting_hr_bpm"),
        ScalarBinding("sleep", "sleep_total_min"), ScalarBinding("sleep", "sleep_in_bed_min"),
        ScalarBinding("sleep", "sleep_awake_min"), ScalarBinding("sleep", "sleep_light_min"),
        ScalarBinding("sleep", "sleep_deep_min"), ScalarBinding("sleep", "sleep_rem_min"),
        ScalarBinding("sleep", "sleep_efficiency", 100), ScalarBinding("sleep", "disturbances"),
        ScalarBinding("respiration", "resp_rate_bpm"), ScalarBinding("recovery", "recovery"),
        ScalarBinding("strain_energy", "strain"), ScalarBinding("oxygen", "spo2_pct"),
        ScalarBinding("temperature", "skin_temp_c"), ScalarBinding("temperature", "skin_temp_dev_c"),
    )
    private val detailBindings = listOf(
        DetailBinding("night_hrv", "hrv_summary", "summary"),
        DetailBinding("night_hrv", "heart_rate_windows", "heart_rate_windows"),
        DetailBinding("respiration", "respiration_summary", "summary"),
    )
    private val sleepDailyCompatibilityKeys = setOf("sleep_onset_at", "wake_onset_at", "sleep_unstaged_min",
        "state_unknown_min", "off_body_min", "main_sleep_group_id", "opportunity_kind", "full_day_sleep_epochs")
    private const val canonicalProjectionState = "canonical_sanitized_v1"
    private val canonicalProjectionKeys = listOf("daily", "nights", "sleep_overrides", "measurements",
        "computed_at", "stale", "compatibility_projection")
    private val nestedHrvFields = listOf("hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm", "overnight_hr_bpm",
        "hrv_summary", "heart_rate_windows", "recovery", "strain", "spo2_pct", "skin_temp_c", "skin_temp_dev_c")
    private val nestedRespirationFields = listOf("resp_rate_bpm", "respiration_summary", "respiration_unavailable_reason")
    private fun ServerComputeFamily.publishable() = authorized && !expired()
    private fun ServerComputeFamily.currentHrvPublishable() = hasImmutableIdentity && !expired() &&
        freshness in setOf("current", "stale") && status in setOf("available", "stale", "insufficient_quality")
    private fun ServerComputeFamily.admittedForCompatibility() = publishable() ||
        family == "current_hrv" && currentHrvPublishable()
    private fun scalarMatches(topLevel: Any?, immutable: Any?, scale: Int): Boolean {
        val topNull = topLevel == null || topLevel === JSONObject.NULL
        val immutableNull = immutable == null || immutable === JSONObject.NULL
        if (topNull || immutableNull) return topNull && immutableNull
        if (topLevel !is Number || immutable !is Number) return false
        val left = runCatching { java.math.BigDecimal(topLevel.toString()).multiply(java.math.BigDecimal.valueOf(scale.toLong())) }
            .getOrNull() ?: return false
        val right = runCatching { java.math.BigDecimal(immutable.toString()) }.getOrNull() ?: return false
        return left.compareTo(right) == 0
    }
    private fun projectedScalar(value: Any?, scale: Int): Any {
        if (value == null || value === JSONObject.NULL) return JSONObject.NULL
        if (scale == 1) return value
        require(value is Number) { "invalid scaled result" }
        return java.math.BigDecimal(value.toString()).divide(java.math.BigDecimal.valueOf(scale.toLong()))
    }
    private fun copyJSON(value: Any?): Any = when (value) {
        null, JSONObject.NULL -> JSONObject.NULL
        is JSONObject -> JSONObject(value.toString())
        is JSONArray -> JSONArray(value.toString())
        else -> value
    }
    private fun stripNightCompatibility(night: JSONObject, keepHrv: Boolean, keepRespiration: Boolean) {
        if (!keepHrv) nestedHrvFields.forEach(night::remove)
        if (!keepRespiration) nestedRespirationFields.forEach(night::remove)
    }
    private fun sanitizeNightCompatibility(values: JSONArray, keepHrv: Boolean, keepRespiration: Boolean) =
        JSONArray().also { result ->
            for (index in 0 until values.length()) {
                val night = JSONObject(values.getJSONObject(index).toString())
                stripNightCompatibility(night, keepHrv, keepRespiration)
                result.put(night)
            }
        }
    private fun decodeDaily(d: JSONObject) = ServerScoreDailyCache(
        hrvRmssdMs = d.num("hrv_rmssd_ms"), restingHrBpm = d.num("resting_hr_bpm")?.toInt(),
        sleepTotalMin = d.num("sleep_total_min"), sleepInBedMin = d.num("sleep_in_bed_min"),
        sleepAwakeMin = d.num("sleep_awake_min"), sleepLightMin = d.num("sleep_light_min"),
        sleepDeepMin = d.num("sleep_deep_min"), sleepRemMin = d.num("sleep_rem_min"),
        sleepEfficiency = d.num("sleep_efficiency"), respRateBpm = d.num("resp_rate_bpm"), computedAt = d.str("computed_at"),
        sleepUnstagedMin = d.num("sleep_unstaged_min"), stateUnknownMin = d.num("state_unknown_min"),
        offBodyMin = d.num("off_body_min"), opportunityKind = d.str("opportunity_kind"),
        recovery = d.num("recovery"), rest = d.num("rest"), strain = d.num("strain"), spo2Pct = d.num("spo2_pct"),
        skinTempC = d.num("skin_temp_c"), skinTempDevC = d.num("skin_temp_dev_c"),
    )
    private fun canonical(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") {
            JSONObject.quote(it) + ":" + canonical(value.opt(it))
        }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.opt(it)) }
        is String -> JSONObject.quote(value)
        is Number -> runCatching { java.math.BigDecimal(value.toString()).stripTrailingZeros().toPlainString() }
            .getOrElse { value.toString() }
        else -> value.toString()
    }
    private fun JSONObject?.orEmpty() = this ?: JSONObject()
}
