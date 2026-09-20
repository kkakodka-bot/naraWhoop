package com.noop.push

import org.json.JSONObject

/** Selected server RMSSD windows only; never substitutes a daily scalar or SDNN. */
data class ServerHrvSeries(
    val windows: List<Window>, val featureStatus: String?, val featureReason: String?,
    val deviceId: String?, val algorithmVersion: String?, val observedThrough: String?, val stale: Boolean,
) {
    data class Window(
        val start: Long, val end: Long, val rmssdMs: Double?, val measurementValid: Boolean,
        val context: String, val baselineEligible: Boolean, val reason: String?, val baselineReason: String?,
        val baselineEffectiveSampleCount: Int?, val baselineRobustZ: Double?, val source: String?,
        val modality: String?, val methodVersion: String?, val observedTimeFraction: Double?, val isGap: Boolean,
    )
    companion object {
        fun from(cache: ServerScoreDayCache?, day: String): ServerHrvSeries {
            val feature = cache?.features?.get("hrv")
            fun result(rows: List<Window>) = ServerHrvSeries(rows, feature?.status, feature?.reason, feature?.deviceId,
                feature?.algorithmVersion, feature?.observedThrough, cache?.stale ?: true)
            if (cache == null || cache.day != day || cache.ownerId.isBlank() || cache.schemaVersion != 2 || feature == null ||
                feature.algorithmVersion != "frwhoop-physiology-2" || feature.deviceId.isNullOrEmpty() || feature.inputRevision == null) {
                return result(emptyList())
            }
            val overlay = runCatching { JSONObject(cache.rawSnapshotJSON ?: "{}").optJSONObject("server_scoring") }.getOrNull()
                ?: return result(emptyList())
            val selected = overlay.optJSONObject("features")?.optJSONObject("hrv") ?: return result(emptyList())
            if (overlay.optString("user_id").lowercase() != cache.ownerId.lowercase() || overlay.optString("day") != day ||
                selected.optString("device_id") != feature.deviceId || selected.optString("algorithm_version") != feature.algorithmVersion ||
                selected.opt("input_revision")?.toString() != feature.inputRevision.toString()) return result(emptyList())
            val rows = overlay.optJSONArray("measurements") ?: return result(emptyList())
            fun JSONObject.text(key: String) = opt(key) as? String
            fun JSONObject.number(key: String) = (opt(key) as? Number)?.toDouble()?.takeIf { it.isFinite() }
            fun JSONObject.integer(key: String) = number(key)?.takeIf {
                it == kotlin.math.floor(it) && it >= -62135596800 && it <= 253402300799
            }?.toLong()
            val parsed = (0 until rows.length()).mapNotNull { index ->
                val row = rows.optJSONObject(index) ?: return@mapNotNull null
                val start = row.integer("start")
                val end = row.integer("end")
                if (row.integer("measurement_schema_version") != 1L || row.text("feature") != "hrv" ||
                    row.text("user_id")?.lowercase() != cache.ownerId.lowercase() || row.text("device_id") != feature.deviceId ||
                    row.text("metric") != "rmssd" || row.text("unit") != "ms" || start == null || end == null ||
                    start % 300 != 0L || end - start != 300L) return@mapNotNull null
                if (row.opt("input_revision")?.toString() != feature.inputRevision.toString()) return@mapNotNull null
                val value = row.number("observed_rmssd_ms")
                val source = row.text("source")
                val modality = row.text("modality")
                val valid = row.opt("measurement_valid") == true && value != null && value >= 0 && row.isNull("reason") &&
                    !source.isNullOrEmpty() && !modality.isNullOrEmpty()
                val context = row.text("context") ?: "unknown"
                val eligible = valid && row.opt("baseline_eligible") == true && context in listOf("sleep", "nap", "quiet_rest")
                val baseline = row.optJSONObject("baseline")
                Window(start, end, value.takeIf { valid }, valid, context, eligible,
                    if (valid) null else row.text("reason") ?: "measurement_unavailable",
                    row.text("baseline_reason") ?: baseline?.text("reason"),
                    baseline?.integer("effective_sample_count")?.takeIf { it in 0..Int.MAX_VALUE }?.toInt(),
                    baseline?.number("robust_z").takeIf { eligible }, source, modality, row.text("algorithm_version"),
                    row.number("observed_time_fraction")?.takeIf { it in 0.0..1.0 }, false)
            }
            val buckets = parsed.groupBy { it.start }
            val first = buckets.keys.minOrNull()
            val last = buckets.keys.maxOrNull()
            if (first == null || last == null || last - first > 76 * 3600) return result(emptyList())
            return result((first..last step 300).map { start ->
                val values = buckets[start]
                if (values == null) gap(start, "window_missing") else if (values.distinct().size == 1) values.first()
                else gap(start, "conflicting_window_records")
            })
        }
        private fun gap(start: Long, reason: String) = Window(start, start + 300, null, false, "unknown", false, reason,
            "measurement_unavailable", null, null, null, null, null, null, true)
    }
}
