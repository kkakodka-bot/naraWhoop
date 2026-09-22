package com.noop.push

import org.json.JSONObject

/** Rendering ownership is durable; each new value still needs current canonical authorization. */
data class ServerMetricOwnership(
    val project: String,
    val ownerId: String,
    val deviceId: String,
    val claims: Map<String, Claim> = emptyMap(),
    val ownedFamilies: Set<String> = emptySet(),
) {
    data class Claim(val metrics: Set<String>, val algorithmVersion: String, val inputRevision: Long,
                     val manifestHash: String?, val featureManifestHash: String?)

    val metrics: Set<String> get() = claims.values.flatMap { it.metrics }.toSet() +
        ownedFamilies.flatMap { ServerComputeContract.familyMetrics[it].orEmpty() }
    fun owns(metric: String) = metric in metrics

    fun presentation(cache: ServerScoreDayCache?, day: String, readFailed: Boolean = false): ServerScoreDayCache? {
        if (cache != null && cache.day == day && cache.ownerId.equals(ownerId, true) &&
            cache.features.values.all { it.deviceId == null || it.deviceId == deviceId } &&
            (cache.compute == null || cache.compute.project.trimEnd('/') == project.trimEnd('/') &&
                cache.compute.families.values.all { it.deviceId == deviceId ||
                    it.deviceId == null && it.reason == "device_registration_pending" && !it.authorized })) {
            return cache.copy(ownedMetrics = metrics + cache.compute?.ownedMetrics.orEmpty(), stale = cache.stale || readFailed,
                readFailure = if (readFailed) "server_read_failed" else cache.readFailure)
        }
        if (metrics.isEmpty()) return null
        return ServerScoreDayCache(day, "per_feature", null, emptyList(), null, false, 0,
            ownerId, features = claims.mapValues { (_, claim) ->
                ServerScoreFeatureCache("pending", "awaiting_server_result", deviceId,
                    claim.algorithmVersion, null, null, null, null, null, null, null)
            }, ownedMetrics = metrics, readFailure = if (readFailed) "server_read_failed" else null)
    }

    // Historical details, baselines and sessions do not have a complete canonical replacement yet.
    val canRetireDailyKernel: Boolean get() = metrics.containsAll(dailyKernelOutputs)

    fun observe(cache: ServerScoreDayCache): ServerMetricOwnership {
        if (!cache.ownerId.equals(ownerId, ignoreCase = true)) return this
        val next = claims.toMutableMap()
        cache.compute?.takeIf { it.project.trimEnd('/') == project.trimEnd('/') }?.families?.forEach { (key, family) ->
            val version = family.algorithmVersion
            val revision = family.inputRevision
            if (family.deviceId == deviceId && family.resultRevision != null && version != null && revision != null) {
                val prior = next[key]
                if (prior?.algorithmVersion != version || prior.inputRevision <= revision)
                    next[key] = Claim(family.metrics, version, revision, family.manifestHash, family.featureManifestHash)
            }
        }
        cache.features.forEach { (key, feature) ->
            if (cache.compute != null) return@forEach
            val version = feature.algorithmVersion
            val revision = feature.inputRevision
            if (key !in featureMetrics || feature.deviceId != deviceId || !feature.isCanonicalAvailable ||
                version == null || revision == null || revision < 0 || feature.computedAt == null) return@forEach
            val prior = next[key]
            if (prior?.algorithmVersion == version && prior.inputRevision > revision) return@forEach
            next[key] = Claim(featureMetrics.getValue(key), version, revision, feature.manifestHash, feature.featureManifestHash)
        }
        val families = cache.compute?.takeIf { it.project.trimEnd('/') == project.trimEnd('/') }
            ?.families?.filterValues { it.deviceId == deviceId ||
                it.deviceId == null && it.reason == "device_registration_pending" && !it.authorized }?.keys.orEmpty()
        return copy(claims = next, ownedFamilies = ownedFamilies + families)
    }

    fun encode(): String = JSONObject().put("project", project).put("ownerId", ownerId).put("deviceId", deviceId)
        .put("ownedFamilies", org.json.JSONArray(ownedFamilies.sorted()))
        .put("claims", JSONObject(claims.mapValues { (_, claim) -> JSONObject()
            .put("metrics", org.json.JSONArray(claim.metrics.sorted()))
            .put("algorithmVersion", claim.algorithmVersion).put("inputRevision", claim.inputRevision)
            .put("manifestHash", claim.manifestHash ?: JSONObject.NULL)
            .put("featureManifestHash", claim.featureManifestHash ?: JSONObject.NULL) })).toString()

    companion object {
        val dailyKernelOutputs = setOf(
            "hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm", "resp_rate_bpm", "recovery", "strain",
            "sleep_sessions", "sleep_total_min", "sleep_in_bed_min", "sleep_awake_min", "sleep_light_min",
            "sleep_deep_min", "sleep_rem_min", "sleep_efficiency", "sleep_performance", "disturbances",
            "steps", "active_kcal_est", "steps_est", "exercise_count", "workouts", "spo2_pct", "spo2_red",
            "spo2_ir", "skin_temp_c", "skin_temp_dev_c", "fitness_age", "vo2max_est", "vitality", "body_age",
            "sleep_need_min", "sleep_debt_min", "sleep_consistency", "historical_baselines",
        )
        val featureMetrics = mapOf(
            "hrv" to setOf("hrv_rmssd_ms", "resting_hr_bpm", "recovery", "strain", "spo2_pct", "skin_temp_c", "skin_temp_dev_c"),
            "respiration" to setOf("resp_rate_bpm"),
            "sleep" to setOf("sleep_performance", "sleep_total_min", "sleep_in_bed_min", "sleep_awake_min",
                "sleep_light_min", "sleep_deep_min", "sleep_rem_min", "sleep_efficiency", "sleep_sessions"),
        )

        fun restore(raw: String?, project: String, ownerId: String, deviceId: String): ServerMetricOwnership {
            val empty = ServerMetricOwnership(project.trimEnd('/'), ownerId.lowercase(), deviceId)
            return runCatching {
                val root = JSONObject(requireNotNull(raw))
                require(root.getString("project") == empty.project && root.getString("ownerId") == empty.ownerId &&
                    root.getString("deviceId") == empty.deviceId)
                val values = root.getJSONObject("claims")
                val owned = root.optJSONArray("ownedFamilies")?.let { array ->
                    (0 until array.length()).map { array.getString(it) }.toSet().also { require(ServerComputeContract.familyIDs.containsAll(it)) }
                }.orEmpty()
                empty.copy(ownedFamilies = owned, claims = values.keys().asSequence().filter { it in featureMetrics || it in ServerComputeContract.familyMetrics }.associateWith { key ->
                    val item = values.getJSONObject(key)
                    val metricArray = item.getJSONArray("metrics")
                    val metrics = (0 until metricArray.length()).map { metricArray.getString(it) }.toSet()
                    require((featureMetrics[key].orEmpty() + ServerComputeContract.familyMetrics[key].orEmpty()).containsAll(metrics))
                    Claim(metrics, item.getString("algorithmVersion").also { require(it.isNotEmpty()) }, item.getLong("inputRevision").also { require(it >= 0) },
                        item.optString("manifestHash").takeUnless { it.isEmpty() || it == "null" },
                        item.optString("featureManifestHash").takeUnless { it.isEmpty() || it == "null" })
                })
            }.getOrDefault(empty)
        }
    }
}
