package com.noop.push

import org.json.JSONObject

/** Selected server respiratory-rate summary; never substitutes a local or vendor scalar. */
data class ServerRespirationSummary(
    val breathsPerMinute: Double?, val mean: Double?, val distribution: List<Double>, val coverage: Double?,
    val acceptedSeconds: Double?, val acceptedWindows: Int?, val totalWindows: Int?, val context: String?,
    val method: String?, val calibrationStatus: String?, val reason: String?, val legacy: Boolean,
    val measurementReason: String? = null,
) {
    companion object {
        fun project(cache: ServerScoreDayCache?, day: String): ServerRespirationSummary? {
            if (cache == null || cache.day != day || cache.ownerId.isBlank()) return null
            val feature = cache.features["respiration"] ?: return null
            val device = feature.deviceId?.takeIf { it.isNotBlank() } ?: return null
            val version = feature.algorithmVersion?.takeIf { it.isNotBlank() } ?: return null
            val overlay = runCatching { JSONObject(cache.rawSnapshotJSON ?: "").getJSONObject("server_scoring") }.getOrNull() ?: return null
            val rawFeature = overlay.optJSONObject("features")?.optJSONObject("respiration") ?: return null
            if (!overlay.optString("user_id").equals(cache.ownerId, ignoreCase = true) || overlay.optString("day") != day ||
                rawFeature.optString("device_id") != device || rawFeature.optString("algorithm_version") != version) return null
            fun number(value: Any?): Double? = (value as? Number)?.toDouble()?.takeIf { it.isFinite() }
            fun count(value: Any?): Int? = number(value)?.takeIf { it >= 0 && it <= Int.MAX_VALUE && it % 1.0 == 0.0 }?.toInt()
            fun text(obj: JSONObject, key: String): String? = (obj.opt(key) as? String)?.takeIf { it.isNotBlank() }
            val daily = overlay.optJSONObject("daily") ?: JSONObject()
            val legacy = version == "frwhoop-server-1"
            val summary = daily.optJSONObject("respiration_summary") ?: JSONObject()
            val scalar = number(daily.opt("resp_rate_bpm"))?.takeIf { it > 0 }
            val median = number(summary.opt("median_bpm"))?.takeIf { it > 0 }
            val mean = number(summary.opt("mean_bpm"))?.takeIf { it > 0 }
            val coverage = number(summary.opt("coverage"))?.takeIf { it in 0.0..1.0 }
            val seconds = number(summary.opt("accepted_seconds"))?.takeIf { it >= 0 }
            val accepted = count(summary.opt("accepted_windows"))
            val total = count(summary.opt("total_windows"))
            val context = text(summary, "context")
            val values = summary.optJSONArray("distribution_bpm")
            val distribution = (0 until (values?.length() ?: 0)).mapNotNull { number(values?.opt(it))?.takeIf { n -> n > 0 } }.sorted()
            val visible = feature.status in setOf("available", "fresh", "stale")
            val measurementReason = text(daily, "respiration_unavailable_reason")
            var reason = feature.reason ?: measurementReason
            var primary = if (visible) scalar else null
            if (!visible) reason = reason ?: "respiration_unavailable"
            if (legacy) {
                reason = reason ?: "legacy_quality_unavailable"
            } else if (primary != null) {
                if (context != "main_sleep") {
                    primary = null; reason = "incompatible_respiration_context"
                } else if (median != scalar || mean == null || coverage == null || coverage == 0.0 || seconds == null || seconds == 0.0 ||
                    accepted == null || accepted == 0 || total == null || accepted > total) {
                    primary = null; reason = "inconsistent_respiration_summary"
                }
            }
            if (primary == null) reason = reason ?: "no_quality_eligible_windows"
            return ServerRespirationSummary(primary, if (legacy) null else mean, if (legacy) emptyList() else distribution,
                if (legacy) null else coverage, if (legacy) null else seconds, if (legacy) null else accepted,
                if (legacy) null else total, if (legacy) null else context, if (legacy) null else text(summary, "method_version"),
                if (legacy) null else text(summary, "calibration_status"), reason, legacy,
                if (primary == null) measurementReason else null)
        }
    }
}
