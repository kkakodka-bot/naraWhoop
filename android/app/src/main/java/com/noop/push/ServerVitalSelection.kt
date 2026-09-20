package com.noop.push

/** Sleep retains server ownership; independent vitals can fall back to local results. */
data class ServerVitalSelection(
    val value: Double?, val fromServer: Boolean, val day: String, val status: String?, val stale: Boolean,
    val sourceFeature: String? = null, val deviceId: String? = null, val algorithmVersion: String? = null,
) {
    enum class Metric { HRV, RESTING_HR, RESPIRATORY, SLEEP, CHARGE, STRAIN, SPO2, SKIN_TEMP }

    companion object {
        /** [overlay] must already be owner scoped and configuration/authentication qualified. */
        fun resolve(metric: Metric, serverEnabled: Boolean, selectedDay: String,
                    overlay: ServerScoreDayCache?, localValue: Double?): ServerVitalSelection {
            if (!serverEnabled) return ServerVitalSelection(localValue, false, selectedDay, null, false)
            // No overlay yet: keep showing locally scored values until the hosted scorer publishes.
            if (overlay == null || overlay.day != selectedDay)
                return ServerVitalSelection(if (metric == Metric.SLEEP) null else localValue,
                    metric == Metric.SLEEP, selectedDay, if (metric == Metric.SLEEP) "unavailable" else null,
                    false, if (metric == Metric.SLEEP) "sleep" else null)
            val (value, featureKey) = when (metric) {
                Metric.HRV -> overlay.daily?.hrvRmssdMs to "hrv"
                Metric.RESTING_HR -> overlay.daily?.restingHrBpm?.toDouble() to "hrv"
                Metric.RESPIRATORY -> overlay.daily?.respRateBpm to "respiration"
                Metric.SLEEP -> overlay.daily?.sleepTotalMin to "sleep"
                Metric.CHARGE -> overlay.daily?.recovery to "hrv"
                Metric.STRAIN -> overlay.daily?.strain to "hrv"
                Metric.SPO2 -> overlay.daily?.spo2Pct to "hrv"
                Metric.SKIN_TEMP -> (overlay.daily?.skinTempC ?: overlay.daily?.skinTempDevC) to "hrv"
            }
            val feature = overlay.features[featureKey]
            val status = feature?.status ?: "unavailable"
            val available = status == "available" || status == "stale"
            // A published feature with this metric still null is not live for the card.
            // Missing sleep can be a deletion or an unknown state. Local episodes cannot resurrect it.
            if (!available || value == null) {
                return ServerVitalSelection(if (metric == Metric.SLEEP) null else localValue,
                    metric == Metric.SLEEP, selectedDay,
                    if (metric == Metric.SLEEP && value == null) "unavailable" else status, overlay.stale,
                    feature?.let { featureKey }, feature?.deviceId, feature?.algorithmVersion)
            }
            return ServerVitalSelection(value, true, selectedDay, status, overlay.stale || status == "stale",
                feature?.let { featureKey }, feature?.deviceId, feature?.algorithmVersion)
        }
    }
}
