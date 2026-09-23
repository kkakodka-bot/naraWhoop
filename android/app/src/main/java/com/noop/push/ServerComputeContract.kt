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
    fun value(metric: String): Any? {
        if (!authorized || expired() || metric !in metrics) return null
        val scoped = JSONObject(json)
        if (!LegacyBeatReadEligibility.permits(algorithmVersion, metric,
                scoped.optJSONObject("details")?.optJSONObject("input_eligibility"))) return null
        LegacyBeatReadEligibility.family(scoped)
        if (scoped.optString("status") !in setOf("available", "stale")) return null
        return scoped.optJSONObject("values")?.opt(metric)?.takeUnless { it == JSONObject.NULL }
    }
    fun number(metric: String): Double? = (value(metric) as? Number)?.toDouble()?.takeIf { it.isFinite() }
    fun unavailableReason(metric: String): String? = if (status == "revoked") null else if (!LegacyBeatReadEligibility.permits(algorithmVersion, metric,
        JSONObject(json).optJSONObject("details")?.optJSONObject("input_eligibility"))) LegacyBeatReadEligibility.reason else
        JSONObject(json).optJSONObject("details")?.optJSONObject("metric_availability")?.optJSONObject(metric)?.optString("reason")?.takeIf { it.isNotBlank() }
    fun detail(name: String): Any? {
        if (!authorized || expired()) return null
        val scoped = JSONObject(json)
        LegacyBeatReadEligibility.family(scoped)
        if (scoped.optString("status") !in setOf("available", "stale")) return null
        return scoped.optJSONObject("details")?.opt(name)?.takeUnless { it == JSONObject.NULL }
    }
    fun usableDecision(nowMs: Long): Boolean = authorized && decisionId != null &&
        expiresAt?.let { runCatching { java.time.Instant.parse(it).toEpochMilli() > nowMs }.getOrDefault(false) } == true &&
        (algorithmVersion != "frwhoop-server-1" || metrics.all { LegacyBeatReadEligibility.permits(algorithmVersion, it,
            JSONObject(json).optJSONObject("details")?.optJSONObject("input_eligibility")) })
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
            require(ProjectURLCanonicalizer.canonicalOrNull(project) == project &&
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
                LegacyBeatReadEligibility.family(f)
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

/** Read eligibility is narrower than retained-v1 identity; this never computes physiology. */
internal object LegacyBeatReadEligibility {
    const val reason = "beat_timing_unverified"
    private val always = setOf("hrv_rmssd_ms", "hrv_sdnn_ms", "resp_rate_bpm", "recovery", "current_hrv",
        "spot_hrv_rmssd_ms", "spot_hrv_sdnn_ms")
    private val sleep = setOf("sleep_total_min", "sleep_awake_min", "sleep_light_min", "sleep_deep_min",
        "sleep_rem_min", "sleep_efficiency", "disturbances", "rest", "sleep_performance", "sleep_onset_at", "wake_onset_at",
        "sleep_unstaged_min", "state_unknown_min", "off_body_min")
    private val nightAlways = always + setOf("hrv_summary", "respiration_summary", "avg_hrv", "avg_hrv_ms", "sdnn_ms")
    private val nightSleep = setOf("asleep_min", "awake_min", "light_min", "deep_min", "rem_min", "efficiency",
        "disturbances", "rest", "sleep_unstaged_min", "state_unknown_min", "off_body_min", "state_coverage")
    fun excluded(marker: JSONObject?): Boolean = marker != null && marker.keys().asSequence().toSet() ==
        setOf("policy_version", "rr_input") && marker.opt("policy_version") == "legacy-rr-excluded-1" &&
        marker.opt("rr_input") == "excluded"
    fun permits(algorithm: String?, metric: String, marker: JSONObject?): Boolean = algorithm != "frwhoop-server-1" ||
        metric !in always && (metric !in sleep || excluded(marker))
    private fun clear(value: JSONObject?, keys: Set<String>) { keys.forEach { value?.put(it, JSONObject.NULL) } }
    private fun nights(rows: org.json.JSONArray?, marked: Boolean) {
        if (rows == null) return
        for (i in 0 until rows.length()) rows.optJSONObject(i)?.let { n ->
            clear(n, nightAlways)
            n.put("respiration_unavailable_reason", reason)
            if (!marked) {
                clear(n, nightSleep)
                n.put("stages", org.json.JSONArray()).put("hypnogram", org.json.JSONArray())
                    .put("measurement_available", false).put("measurement_unavailable_reason", reason)
            }
        }
    }
    fun family(f: JSONObject) {
        if (f.opt("algorithm_version") != "frwhoop-server-1") return
        // Preserve the original strict decoder failure for malformed authorization and
        // unavailable numeric payloads. A read gate cannot turn them into valid missingness.
        if (f.opt("status") !in setOf("available", "stale", "insufficient_quality")) return
        if (f.opt("owner") != "server" || f.opt("canonical_qualification") != "retained_legacy" ||
            (f.opt("manifest_hash") as? String)?.matches(Regex("^[a-f0-9]{64}$")) != true ||
            (f.opt("result_revision") as? String)?.matches(Regex("^(sha256:[a-f0-9]{64}|compute:[0-9]+|session:[0-9]+)$")) != true ||
            f.opt("input_revision") !is Number || f.opt("computed_at") !is String ||
            (f.opt("device_id") as? String).isNullOrBlank()) return
        val values = f.optJSONObject("values") ?: return
        val details = f.optJSONObject("details") ?: return
        val marker = details.optJSONObject("input_eligibility")
        val marked = excluded(marker)
        val unavailable = details.optJSONObject("metric_availability") ?: JSONObject()
        for (key in values.keys().asSequence().toList()) if (!permits("frwhoop-server-1", key, marker)) {
            values.put(key, JSONObject.NULL)
            unavailable.put(key, JSONObject().put("status", "unqualified").put("reason", reason))
        }
        details.put("metric_availability", unavailable).put("read_eligibility_policy", "legacy-beat-read-1")
        if (!marked) details.put("input_eligibility", JSONObject.NULL)
        if (values.has("hrv_rmssd_ms") || values.has("resp_rate_bpm")) details.put("summary", JSONObject.NULL)
        if (values.has("current_hrv")) details.put("measurements", org.json.JSONArray()).remove("selected_window")
        if (values.has("sleep_sessions")) {
            nights(values.optJSONArray("sleep_sessions"), marked); nights(details.optJSONArray("nights"), marked)
            if (!marked) {
                details.optJSONObject("daily_compatibility")?.let { compatibility ->
                    clear(compatibility, sleep.filter { compatibility.has(it) }.toSet())
                }
                details.optJSONObject("daily_compatibility")?.put("full_day_sleep_epochs", org.json.JSONArray())
            }
        }
        if (values.keys().asSequence().all { values.isNull(it) } &&
            values.keys().asSequence().any { it in always }) {
            f.put("status", "unqualified").put("reason", reason).put("expires_at", JSONObject.NULL)
        }
    }
    fun apply(root: JSONObject) {
        val overlay = root.optJSONObject("server_scoring") ?: return
        val features = overlay.optJSONObject("features") ?: return
        fun legacy(feature: String) = features.optJSONObject(feature)?.optString("algorithm_version") == "frwhoop-server-1"
        val compute = overlay.optJSONObject("compute") ?: root.optJSONObject("compute")
        val families = compute?.optJSONObject("families")
        val marked = excluded(if (compute == null) features.optJSONObject("sleep")?.optJSONObject("input_eligibility")
            else families?.optJSONObject("sleep")?.optJSONObject("details")?.optJSONObject("input_eligibility"))
        val daily = overlay.optJSONObject("daily")
        if (legacy("hrv")) clear(daily, setOf("hrv_rmssd_ms", "hrv_sdnn_ms", "hrv_summary", "recovery"))
        if (legacy("respiration")) {
            clear(daily, setOf("resp_rate_bpm", "respiration_summary"))
            daily?.put("respiration_unavailable_reason", reason)
        }
        if (legacy("sleep")) {
            nights(overlay.optJSONArray("nights"), marked)
            if (!marked) { clear(daily, sleep); daily?.put("full_day_sleep_epochs", org.json.JSONArray()) }
        }
        if (legacy("hrv")) {
            val filtered = org.json.JSONArray()
            overlay.optJSONArray("measurements")?.let { rows -> for (i in 0 until rows.length()) {
                if (rows.optJSONObject(i)?.optString("feature") != "hrv") filtered.put(rows.get(i))
            } }
            overlay.put("measurements", filtered)
        }
        families?.keys()?.asSequence()?.toList()?.forEach { family(families.getJSONObject(it)) }
        if (listOf("hrv", "sleep", "respiration").any(::legacy)) {
            // A cached compatibility projection must be rebuilt under this read policy.
            // Scope, immutable identity and all retained values still undergo normal validation.
            overlay.remove("compatibility_projection")
        }
    }
}
