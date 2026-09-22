package com.noop.push

/** Once a metric is owned, null, pending and failure remain server results. */
data class ServerVitalSelection(
    val value: Double?, val fromServer: Boolean, val day: String, val status: String?, val stale: Boolean,
    val sourceFeature: String? = null, val deviceId: String? = null, val algorithmVersion: String? = null,
    val resultRevision: String? = null,
) {
    val displayDiagnostic: ServerScoreStageDiagnostic get() = ServerScoreStageDiagnostic("displayed",
        if (value != null) "available" else "unavailable", if (!fromServer) "local_producer_retained"
            else if (value == null) "metric_unavailable" else "server_metric_selected")
    enum class Metric(val key: String, val feature: String) {
        HRV("hrv_rmssd_ms", "hrv"), RESTING_HR("resting_hr_bpm", "hrv"),
        RESPIRATORY("resp_rate_bpm", "respiration"), SLEEP("sleep_total_min", "sleep"), REST("sleep_performance", "sleep"),
        CHARGE("recovery", "hrv"), STRAIN("strain", "hrv"), SPO2("spo2_pct", "hrv"),
        SKIN_TEMP("skin_temp_c", "hrv")
    }

    companion object {
        /** [overlay] must already be owner scoped and configuration/authentication qualified. */
        fun resolve(metric: Metric, serverEnabled: Boolean, selectedDay: String,
                    overlay: ServerScoreDayCache?, localValue: Double?): ServerVitalSelection {
            val family = overlay?.takeIf { it.day == selectedDay }?.compute?.familyFor(metric.key)
            if (family != null) return ServerVitalSelection(family.number(metric.key), true, selectedDay,
                overlay.readFailure ?: family.reason ?: family.status, overlay.stale || family.status == "stale",
                family.family, family.deviceId, family.algorithmVersion, family.resultRevision)
            val feature = overlay?.features?.get(metric.feature)
            val owned = overlay?.ownedMetrics?.contains(metric.key) ?: serverEnabled
            if (!owned) return ServerVitalSelection(localValue, false, selectedDay, null, false)
            if (overlay == null || overlay.day != selectedDay)
                return ServerVitalSelection(null, true, selectedDay, "pending", false, metric.feature)
            val (value, featureKey) = when (metric) {
                Metric.HRV -> overlay.daily?.hrvRmssdMs to "hrv"
                Metric.RESTING_HR -> overlay.daily?.restingHrBpm?.toDouble() to "hrv"
                Metric.RESPIRATORY -> overlay.daily?.respRateBpm to "respiration"
                Metric.SLEEP -> overlay.daily?.sleepTotalMin to "sleep"
                Metric.REST -> overlay.daily?.rest to "sleep"
                Metric.CHARGE -> overlay.daily?.recovery to "hrv"
                Metric.STRAIN -> overlay.daily?.strain to "hrv"
                Metric.SPO2 -> overlay.daily?.spo2Pct to "hrv"
                Metric.SKIN_TEMP -> overlay.daily?.skinTempC to "hrv"
            }
            val status = feature?.status ?: "unavailable"
            val available = feature?.isCanonicalAvailable == true
            if (!available || value == null) {
                val missingState = overlay.readFailure ?: feature?.processingStatus?.takeIf { it in setOf("pending", "running", "retry", "failed", "exhausted") }
                    ?: feature?.reason ?: if (value == null && available) "insufficient_input" else "unavailable"
                return ServerVitalSelection(null, true, selectedDay, missingState, overlay.stale,
                    feature?.let { featureKey }, feature?.deviceId, feature?.algorithmVersion)
            }
            return ServerVitalSelection(value, true, selectedDay, status, overlay.stale || status == "stale",
                feature?.let { featureKey }, feature?.deviceId, feature?.algorithmVersion)
        }
    }
}
