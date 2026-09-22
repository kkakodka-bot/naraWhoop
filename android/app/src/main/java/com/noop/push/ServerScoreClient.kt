package com.noop.push

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

object ServerScoreClient {
    suspend fun fetchDaySnapshot(context: Context, day: String): ServerScoreDayCache =
        withContext(Dispatchers.IO) {
            val response = AccountScoringRpc(com.noop.account.AccountStorageContext.capture(context)).snapshot(day)
            val snapshot = response.snapshot ?: error("Server calculation pending or unavailable")
            snapshot.legacy(System.currentTimeMillis(), response.pending)
        }

    fun parseSnapshot(body: String, day: String): ServerScoreDayCache {
        val root = JSONObject(body)
        val overlay = root.optJSONObject("server_scoring") ?: JSONObject()
        if (overlay.optString("algorithm_version") != ServerScoringSettings.ALGORITHM_VERSION) {
            return ServerScoreDayCache(
                day = day,
                algorithmVersion = ServerScoringSettings.ALGORITHM_VERSION,
                daily = null,
                nights = emptyList(),
                computedAt = null,
                stale = true,
                fetchedAtMs = System.currentTimeMillis(),
            )
        }
        val dailyObj = overlay.optJSONObject("daily")
        val daily = dailyObj?.let {
            ServerScoreDailyCache(
                hrvRmssdMs = it.optDoubleOrNull("hrv_rmssd_ms"),
                restingHrBpm = it.optIntOrNull("resting_hr_bpm"),
                sleepTotalMin = it.optDoubleOrNull("sleep_total_min"),
                sleepInBedMin = it.optDoubleOrNull("sleep_in_bed_min"),
                sleepAwakeMin = it.optDoubleOrNull("sleep_awake_min"),
                sleepLightMin = it.optDoubleOrNull("sleep_light_min"),
                sleepDeepMin = it.optDoubleOrNull("sleep_deep_min"),
                sleepRemMin = it.optDoubleOrNull("sleep_rem_min"),
                sleepEfficiency = it.optDoubleOrNull("sleep_efficiency"),
                respRateBpm = it.optDoubleOrNull("resp_rate_bpm"),
                computedAt = it.optString("computed_at").takeIf { s -> s.isNotBlank() },
            )
        }
        val nightsArr = overlay.optJSONArray("nights") ?: JSONArray()
        val nights = buildList {
            for (i in 0 until nightsArr.length()) {
                val n = nightsArr.getJSONObject(i)
                add(
                    ServerScoreNightCache(
                        id = n.optString("id", UUID.randomUUID().toString()),
                        startAt = n.optString("start_at"),
                        endAt = n.optString("end_at"),
                        isNap = n.optBoolean("is_nap", false),
                        asleepMin = n.optDoubleOrNull("asleep_min"),
                        inBedMin = n.optDoubleOrNull("in_bed_min"),
                        lightMin = n.optDoubleOrNull("light_min"),
                        deepMin = n.optDoubleOrNull("deep_min"),
                        remMin = n.optDoubleOrNull("rem_min"),
                        awakeMin = n.optDoubleOrNull("awake_min"),
                        efficiency = n.optDoubleOrNull("efficiency"),
                        hrvRmssdMs = n.optDoubleOrNull("hrv_rmssd_ms"),
                        restingHrBpm = n.optIntOrNull("resting_hr_bpm"),
                    ),
                )
            }
        }
        return ServerScoreDayCache(
            day = day,
            algorithmVersion = ServerScoringSettings.ALGORITHM_VERSION,
            daily = daily,
            nights = nights,
            computedAt = overlay.optString("computed_at").takeIf { it.isNotBlank() },
            stale = overlay.optBoolean("stale", true),
            fetchedAtMs = System.currentTimeMillis(),
        )
    }

    private fun JSONObject.optDoubleOrNull(key: String): Double? =
        if (!has(key) || isNull(key)) null else optDouble(key)

    private fun JSONObject.optIntOrNull(key: String): Int? =
        if (!has(key) || isNull(key)) null else optInt(key)
}
