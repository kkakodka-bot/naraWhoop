package com.noop.push

import org.json.JSONObject

/** One immutable family result, shared by all consumers. Null has no numerical substitute. */
data class ServerComputeFamily(
    val family: String, val project: String, val ownerId: String, val deviceId: String?,
    val sourceId: String?, val window: String, val timezone: String?, val metrics: Set<String>,
    val status: String, val reason: String?, val resultRevision: String?, val inputRevision: Long?,
    val algorithmVersion: String?, val configurationVersion: String?, val manifestHash: String?,
    val featureManifestHash: String?, val canonicalQualification: String?,
    val computedAt: String?, val observedThrough: String?, val expiresAt: String?, val decisionId: String?,
    val json: String,
) {
    val authorized: Boolean get() = resultRevision != null && inputRevision != null &&
        computedAt != null && !deviceId.isNullOrBlank() && !algorithmVersion.isNullOrBlank() &&
        status in setOf("available", "fresh", "stale") &&
        manifestHash?.matches(Regex("^[a-f0-9]{64}$")) == true &&
        (algorithmVersion == "frwhoop-server-1" && canonicalQualification == "retained_legacy" ||
            canonicalQualification == "signed_reference_approval" &&
            featureManifestHash?.matches(Regex("^[a-f0-9]{64}$")) == true)
    fun value(metric: String): Any? = if (!authorized || metric !in metrics) null else
        JSONObject(json).optJSONObject("values")?.opt(metric)?.takeUnless { it == JSONObject.NULL }
    fun number(metric: String): Double? = (value(metric) as? Number)?.toDouble()?.takeIf { it.isFinite() }
    fun detail(name: String): Any? = if (authorized) JSONObject(json).optJSONObject("details")?.opt(name)
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
        private val states = setOf("available", "fresh", "stale", "unsupported", "insufficient_input", "insufficient_quality",
            "unqualified", "processing", "pending", "failed", "unavailable", "revoked")
        fun decode(compute: JSONObject?, owner: String, day: String): ServerComputeContract? {
            if (compute == null) return null
            require(compute.getString("mode") == "final_hosted" && compute.getString("policy_version") == "vps-only-1")
            val project = compute.getString("project").trimEnd('/')
            require(project.isNotBlank() && compute.getString("owner_id").equals(owner, true))
            val source = compute.text("source_id")
            val raw = compute.getJSONObject("families")
            require(raw.keys().asSequence().toSet() == familyIDs) { "Incomplete compute family contract" }
            val results = familyIDs.associateWith { key ->
                val f = raw.getJSONObject(key)
                decodeFamily(f, key, project, owner, source, day, compute.text("device_id"))
            }
            require(results.values.flatMap { it.metrics }.let { it.size == it.toSet().size }) { "Ambiguous metric family" }
            return ServerComputeContract(project, owner.lowercase(), source, results)
        }
        fun decodeFamily(f: JSONObject, key: String, project: String, owner: String, source: String?,
                         window: String, device: String?): ServerComputeFamily {
                require(key in familyIDs)
                require(f.getString("owner") == "server" && f.getString("status") in states)
                require(f.text("project")?.trimEnd('/') == project && f.text("owner_id")?.lowercase() == owner.lowercase())
                require(f.text("source_id") == source && f.getString("window") == window)
                val ids = f.getJSONArray("metrics").let { a -> (0 until a.length()).map { a.getString(it) }.toSet() }
                require(ids == familyMetrics.getValue(key)) { "Metric family contract mismatch" }
                val input = (f.opt("input_revision") as? Number)?.let { number -> number.toLong().also {
                    require(it >= 0 && number.toDouble().isFinite() && number.toDouble() == it.toDouble())
                } }
                val revision = f.text("result_revision")
                require(revision == null || (input != null && f.text("computed_at") != null &&
                    revision.matches(Regex("^(sha256:[a-f0-9]{64}|compute:[0-9]+|session:[0-9]+)$"))))
                require(f.text("device_id") == device) { "Cross-device family result" }
                listOf("computed_at", "observed_through", "expires_at").forEach { name ->
                    f.text(name)?.let(java.time.Instant::parse)
                }
                return ServerComputeFamily(key, project, owner.lowercase(), f.text("device_id"), source, window, f.text("timezone_id"), ids,
                    f.getString("status"), f.text("reason"), revision, input, f.text("algorithm_version"),
                    f.text("configuration_version"), f.text("manifest_hash"), f.text("feature_manifest_hash"),
                    f.text("canonical_qualification"), f.text("computed_at"), f.text("observed_through"),
                    f.text("expires_at"), f.text("decision_id"), f.toString())
        }
        internal fun JSONObject.text(key: String): String? = (opt(key) as? String)?.takeIf { it.isNotBlank() }
    }
}
