package com.noop.push

import org.json.JSONObject

/** One immutable family result, shared by all consumers. Null has no numerical substitute. */
data class ServerComputeFamily(
    val family: String, val project: String, val ownerId: String, val deviceId: String?,
    val sourceId: String?, val window: String, val timezone: String?, val metrics: Set<String>,
    val status: String, val reason: String?, val resultRevision: String?, val inputRevision: Long?,
    val algorithmVersion: String?, val configurationVersion: String?, val manifestHash: String?,
    val featureManifestHash: String?, val canonicalQualification: String?,
    val computedAt: String?, val observedThrough: String?, val freshness: String, val expiresAt: String?, val decisionId: String?,
    val json: String,
) {
    /** Qualification and immutable identity are independent of whether this result currently has a value. */
    val hasImmutableIdentity: Boolean get() = resultRevision != null && inputRevision != null &&
        computedAt != null && !deviceId.isNullOrBlank() && !algorithmVersion.isNullOrBlank() &&
        manifestHash?.matches(Regex("^[a-f0-9]{64}$")) == true &&
        (algorithmVersion == "frwhoop-server-1" && canonicalQualification == "retained_legacy" ||
            canonicalQualification == "signed_reference_approval" &&
            featureManifestHash?.matches(Regex("^[a-f0-9]{64}$")) == true)
    val authorized: Boolean get() = hasImmutableIdentity && status in setOf("available", "stale") &&
        freshness in setOf("current", "stale")
    fun expired(nowMs: Long = System.currentTimeMillis()): Boolean = expiresAt?.let {
        runCatching { java.time.Instant.parse(it).toEpochMilli() <= nowMs }.getOrDefault(true)
    } ?: false
    fun value(metric: String): Any? = if (!authorized || expired() || metric !in metrics) null else
        JSONObject(json).optJSONObject("values")?.opt(metric)?.takeUnless { it == JSONObject.NULL }
    fun number(metric: String): Double? = (value(metric) as? Number)?.toDouble()?.takeIf { it.isFinite() }
    fun detail(name: String): Any? = if (authorized && !expired()) JSONObject(json).optJSONObject("details")?.opt(name)
        ?.takeUnless { it == JSONObject.NULL } else null
    fun usableDecision(nowMs: Long): Boolean = authorized && decisionId != null &&
        expiresAt?.let { runCatching { java.time.Instant.parse(it).toEpochMilli() > nowMs }.getOrDefault(false) } == true
}

data class ServerComputeContract(val project: String, val ownerId: String, val sourceId: String?,
                                 val families: Map<String, ServerComputeFamily>) {
    val ownedMetrics: Set<String> get() = families.values.flatMap { it.metrics }.toSet()
    fun familyFor(metric: String): ServerComputeFamily? = families.values.singleOrNull { metric in it.metrics }
    companion object {
        val familyMetrics = mapOf(
            "live_hr_selection" to setOf("live_hr_bpm"),
            "night_hrv" to setOf("hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm"),
            "current_hrv" to setOf("current_hrv"),
            "spot_hrv" to setOf("spot_hrv_rmssd_ms", "spot_hrv_sdnn_ms"),
            "sleep" to setOf("sleep_total_min", "sleep_in_bed_min", "sleep_awake_min", "sleep_light_min", "sleep_deep_min", "sleep_rem_min", "sleep_efficiency", "disturbances", "sleep_sessions"),
            "sleep_history" to setOf("sleep_performance", "hours_vs_needed_pct", "sleep_consistency", "restorative_pct", "restorative_min", "sleep_need_min", "sleep_debt_min"),
            "respiration" to setOf("resp_rate_bpm"), "recovery" to setOf("recovery"),
            "strain_energy" to setOf("strain", "active_kcal_est", "avg_hr", "max_hr", "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min", "strength_min"),
            "steps" to setOf("steps", "steps_est"),
            "workouts" to setOf("exercise_count", "workouts", "workout_strain", "workout_kcal", "workout_hr_recovery"),
            "live_workout" to setOf("live_workout_effort"),
            "oxygen" to setOf("spo2_pct", "spo2_red", "spo2_ir", "spo2_candidate"),
            "temperature" to setOf("skin_temp_c", "skin_temp_dev_c"), "intraday_temperature" to setOf("temperature_5min_c"),
            "ppg_hr" to setOf("derived_ppg_hr"),
            "stress" to setOf("stress", "daytime_stress_mean", "daytime_stress_high_min", "baevsky_stress_index", "frequency_hrv"),
            "stress_events" to setOf("stress_onset"), "illness" to setOf("illness_score", "illness_distance"),
            "cycle" to setOf("cycle_phase", "cycle_index"), "circadian" to setOf("circadian_phase_hour", "circadian_offset_min"),
            "readiness_load" to setOf("readiness", "training_load", "acute_load", "chronic_load", "training_balance", "acwr", "training_monotony"),
            "fitness_longevity" to setOf("fitness_age", "vo2max_est", "vitality", "body_age"),
            "baselines" to setOf("historical_baselines", "recovery_drivers", "recovery_forecast"),
            "biofeedback" to setOf("resonance_frequency", "resonance_pace"),
            "live_coaching" to setOf("coaching_hr_band", "coaching_decision"), "insights" to setOf("insights"))
        val metricIDs = familyMetrics.values.flatten().toSet()
        val familyIDs = setOf("live_hr_selection", "night_hrv", "current_hrv", "spot_hrv", "sleep", "sleep_history",
            "respiration", "recovery", "strain_energy", "steps", "workouts", "live_workout", "oxygen", "temperature",
            "intraday_temperature", "ppg_hr", "stress", "stress_events", "illness", "cycle", "circadian", "readiness_load",
            "fitness_longevity", "baselines", "biofeedback", "live_coaching", "insights")
        private val states = setOf("available", "stale", "unsupported", "insufficient_input", "insufficient_quality",
            "unqualified", "processing", "failed", "unavailable", "revoked")
        fun decode(compute: JSONObject?, owner: String, day: String): ServerComputeContract? {
            if (compute == null) return null
            require(compute.getString("mode") == "final_hosted" && compute.getString("policy_version") == "vps-only-1")
            require(canonicalUuid(owner)) { "Invalid compute owner" }
            val project = compute.getString("project").trimEnd('/')
            require(AccountScope.canonicalProjectURL(project) == project &&
                compute.getString("owner_id").equals(owner, true) && compute.getString("day") == day) {
                "Invalid compute scope"
            }
            val source = compute.getString("source_id").also { require(canonicalUuid(it)) { "Invalid compute source" } }
            val device = compute.optionalString("device_id")
            require(device == null || canonicalUuid(device)) { "Invalid compute device" }
            val raw = compute.getJSONObject("families")
            require(raw.keys().asSequence().toSet() == familyIDs) { "Incomplete compute family contract" }
            val results = familyIDs.associateWith { key ->
                val f = raw.getJSONObject(key)
                decodeFamily(f, key, project, owner, source, day, device)
            }
            require(results.values.flatMap { it.metrics }.let { it.size == it.toSet().size }) { "Ambiguous metric family" }
            return ServerComputeContract(project, owner.lowercase(), source, results)
        }
        fun decodeFamily(f: JSONObject, key: String, project: String, owner: String, source: String,
                         window: String, device: String?): ServerComputeFamily {
                require(key in familyIDs)
                val status = f.getString("status")
                require(f.getString("owner") == "server" && status in states)
                require(f.getString("project").trimEnd('/') == project &&
                    f.getString("owner_id").lowercase() == owner.lowercase())
                require(f.getString("source_id") == source && f.getString("window") == window)
                val ids = f.getJSONArray("metrics").let { a -> (0 until a.length()).map { a.getString(it) }.toSet() }
                require(ids == familyMetrics.getValue(key)) { "Metric family contract mismatch" }
                val inputValue = f.opt("input_revision")
                require(inputValue == null || inputValue === JSONObject.NULL || inputValue is Number) {
                    "Invalid compute input revision"
                }
                val input = (inputValue as? Number)?.let { number -> number.toLong().also {
                    require(it >= 0 && number.toDouble().isFinite() && number.toDouble() == it.toDouble())
                } }
                val revision = f.optionalString("result_revision")
                val freshness = f.getString("freshness")
                require(freshness in setOf("current", "stale", "expired", "unavailable")) { "Invalid compute freshness" }
                val computedAt = f.optionalTimestamp("computed_at")
                val observedThrough = f.optionalTimestamp("observed_through")
                val expiresAt = f.optionalTimestamp("expires_at")
                require(revision == null || (input != null && computedAt != null &&
                    revision.matches(Regex("^(sha256:[a-f0-9]{64}|compute:[0-9]+|session:[0-9]+)$"))))
                val familyDevice = f.optionalString("device_id")
                require(familyDevice == device && (familyDevice == null || canonicalUuid(familyDevice))) {
                    "Cross-device family result"
                }
                val timezone = f.optionalString("timezone_id")
                timezone?.let { runCatching { java.time.ZoneId.of(it) }.getOrElse { throw IllegalArgumentException("Invalid compute timezone", it) } }
                val values = f.getJSONObject("values")
                val valueKeys = values.keys().asSequence().toSet()
                require(valueKeys == familyMetrics.getValue(key)) { "Metric value contract mismatch" }
                require(status in setOf("available", "stale") || valueKeys.all { values.opt(it) === JSONObject.NULL }) {
                    "Unavailable family cannot carry values"
                }
                f.getJSONObject("details")
                val family = ServerComputeFamily(key, project, owner.lowercase(), familyDevice, source, window, timezone, ids,
                    status, f.text("reason"), revision, input, f.text("algorithm_version"),
                    f.text("configuration_version"), f.text("manifest_hash"), f.text("feature_manifest_hash"),
                    f.text("canonical_qualification"), computedAt, observedThrough,
                    freshness, expiresAt, f.text("decision_id"), f.toString())
                require(status !in setOf("available", "stale") || family.hasImmutableIdentity) {
                    "Available family lacks canonical authorization"
                }
                return family
        }
        private fun canonicalUuid(value: String): Boolean = runCatching {
            java.util.UUID.fromString(value).toString().equals(value, ignoreCase = true)
        }.getOrDefault(false)
        private fun JSONObject.optionalString(key: String): String? {
            val value = opt(key)
            require(value == null || value === JSONObject.NULL || value is String) { "$key must be a string or null" }
            return (value as? String)?.also { require(it.isNotBlank()) { "$key cannot be blank" } }
        }
        private fun JSONObject.optionalTimestamp(key: String): String? = optionalString(key)?.also {
            java.time.Instant.parse(it)
        }
        internal fun JSONObject.text(key: String): String? = (opt(key) as? String)?.takeIf { it.isNotBlank() }
    }
}
