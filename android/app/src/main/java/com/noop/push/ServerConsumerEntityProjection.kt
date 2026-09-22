package com.noop.push

import com.noop.data.DailyMetric
import com.noop.data.SleepSession

/** Database projections kept outside the platform-neutral result admission contract. */
object ServerConsumerEntityProjection {
    fun day(cache: ServerScoreDayCache): DailyMetric? {
        val compute = cache.compute ?: return null
        val device = compute.families.values.mapNotNull { it.deviceId }.distinct().singleOrNull() ?: return null
        fun n(key: String) = ServerConsumerProjection.number(cache, key)
        return DailyMetric(device, cache.day, totalSleepMin = n("sleep_total_min"), efficiency = n("sleep_efficiency")?.div(100.0),
            deepMin = n("sleep_deep_min"), remMin = n("sleep_rem_min"), lightMin = n("sleep_light_min"),
            disturbances = n("disturbances")?.toInt(), restingHr = n("resting_hr_bpm")?.toInt(),
            avgHrv = n("hrv_rmssd_ms"), avgSdnn = n("hrv_sdnn_ms"), recovery = n("recovery"), strain = n("strain"),
            exerciseCount = n("exercise_count")?.toInt(), spo2Pct = n("spo2_pct"), skinTempC = n("skin_temp_c"),
            skinTempDevC = n("skin_temp_dev_c"), respRateBpm = n("resp_rate_bpm"), steps = n("steps")?.toInt(),
            activeKcalEst = n("active_kcal_est"), spo2Red = n("spo2_red")?.toInt(), spo2Ir = n("spo2_ir")?.toInt())
    }

    fun sleeps(cache: ServerScoreDayCache): List<SleepSession> {
        val family = cache.compute?.families?.get("sleep")?.takeIf { it.authorized && !it.expired() } ?: return emptyList()
        return cache.nights.mapNotNull { night ->
            val start = runCatching { java.time.Instant.parse(night.startAt).epochSecond }.getOrNull() ?: return@mapNotNull null
            val end = runCatching { java.time.Instant.parse(night.endAt).epochSecond }.getOrNull() ?: return@mapNotNull null
            if (end <= start || night.deviceId != family.deviceId) return@mapNotNull null
            val stages = org.json.JSONArray(night.stages.map { s -> org.json.JSONObject().put("start", s.start)
                .put("end", s.end).put("stage", s.stage).put("state", s.state) }).toString()
            SleepSession(requireNotNull(family.deviceId), start, end, night.efficiency, night.restingHrBpm,
                night.hrvRmssdMs, stages, userEdited = night.manualEdit == true)
        }
    }
}
