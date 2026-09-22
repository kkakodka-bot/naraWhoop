package com.frwhoop.scoring.derived

import com.frwhoop.scoring.scoring.ServerScoreBundle
import com.noop.analytics.DetectedSleep
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

/** Archive JSON for the derived lane — locked HRV/sleep scope only. */
object DerivedArchivePayload {
    fun build(bundle: ServerScoreBundle, computedAt: Instant = Instant.now()): JSONObject {
        val daily = bundle.result.daily
        val mainSleep = bundle.result.sleepSessions.maxByOrNull { it.end - it.start }
        val inBedMin = mainSleep?.let { (it.end - it.start) / 60.0 }
        val asleepMin = daily.totalSleepMin
        val awakeMin = if (inBedMin != null && asleepMin != null) inBedMin - asleepMin else null
        val iso = computedAt.toString()

        val dailyObj = JSONObject()
            .put("day", bundle.day)
            .put("source_device_id", bundle.deviceId)
            .put("computed_at", iso)
            .put("hrv_rmssd_ms", daily.avgHrv)
            .put("hrv_sdnn_ms", daily.avgSdnn)
            .put("resting_hr_bpm", daily.restingHr)
            .put("resp_rate_bpm", daily.respRateBpm)
            .put("sleep_total_min", daily.totalSleepMin)
            .put("sleep_in_bed_min", inBedMin)
            .put("sleep_awake_min", awakeMin)
            .put("sleep_light_min", daily.lightMin)
            .put("sleep_deep_min", daily.deepMin)
            .put("sleep_rem_min", daily.remMin)
            .put("sleep_efficiency", daily.efficiency)
            .put("sleep_onset_at", mainSleep?.start?.let { Instant.ofEpochSecond(it).toString() })
            .put("wake_onset_at", mainSleep?.end?.let { Instant.ofEpochSecond(it).toString() })
            .put("overnight_hr_bpm", mainSleep?.restingHR)
            .put("disturbances", daily.disturbances)

        val nights = JSONArray()
        for (session in bundle.result.sleepSessions) {
            nights.put(sessionToJson(session, bundle, iso))
        }

        val deviceUuid = runCatching { java.util.UUID.fromString(bundle.deviceId) }.getOrNull()
        return JSONObject()
            .put("algorithm_version", bundle.algorithmVersion)
            .put("user_id", bundle.userId.toString())
            .put("device_id", deviceUuid?.toString() ?: bundle.deviceId)
            .put("day", bundle.day)
            .put("computed_at", iso)
            .put("daily", dailyObj)
            .put("nights", nights)
    }

    private fun sessionToJson(session: DetectedSleep, bundle: ServerScoreBundle, computedAt: String): JSONObject {
        val stages = JSONArray()
        for (seg in session.stages) {
            stages.put(
                JSONObject()
                    .put("start", seg.start)
                    .put("end", seg.end)
                    .put("stage", seg.stage),
            )
        }
        val asleepMin = session.stages
            .filter { it.stage != "wake" }
            .sumOf { (it.end - it.start) } / 60.0
        val inBedMin = (session.end - session.start) / 60.0
        return JSONObject()
            .put("period_day", bundle.day)
            .put("device_id", bundle.deviceId)
            .put("start_at", Instant.ofEpochSecond(session.start).toString())
            .put("end_at", Instant.ofEpochSecond(session.end).toString())
            .put("is_nap", false)
            .put("in_bed_min", inBedMin)
            .put("asleep_min", asleepMin)
            .put("efficiency", session.efficiency)
            .put("resting_hr_bpm", session.restingHR)
            .put("hrv_rmssd_ms", session.avgHRV)
            .put("stages", stages)
            .put("hypnogram", JSONArray())
            .put("computed_at", computedAt)
    }
}
