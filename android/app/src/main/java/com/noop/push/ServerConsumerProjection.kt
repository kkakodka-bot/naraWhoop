package com.noop.push

/** Typed rendering adapters, not scoring. Every emitted number retains its source envelope. */
object ServerConsumerProjection {
    fun sameReadState(current: ServerScoreDayCache?, saved: ServerScoreDayCache): Boolean =
        current != null && current.day == saved.day && current.ownerId == saved.ownerId &&
            current.compute == saved.compute && current.stale == saved.stale && current.readFailure == saved.readFailure

    fun number(cache: ServerScoreDayCache?, metric: String): Double? = cache?.compute?.familyFor(metric)?.number(metric)
    fun revisions(cache: ServerScoreDayCache?): Map<String, String> = cache?.compute?.families.orEmpty()
        .mapNotNull { (key, family) -> family.resultRevision?.let { key to it } }.toMap()
    fun metricKey(key: String): String = when (key) {
        "hrv", "avg_hrv" -> "hrv_rmssd_ms"; "rhr", "resting_hr" -> "resting_hr_bpm"
        "sleep_total", "sleep_minutes", "total_sleep_min" -> "sleep_total_min"
        "deep_min" -> "sleep_deep_min"; "rem_min" -> "sleep_rem_min"; "light_min", "core_min" -> "sleep_light_min"
        "skin_temp" -> "skin_temp_c"; "resp_rate" -> "resp_rate_bpm"; "calories" -> "active_kcal_est"
        else -> key
    }
}
