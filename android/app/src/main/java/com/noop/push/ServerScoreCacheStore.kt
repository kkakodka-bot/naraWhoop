package com.noop.push

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/** SharedPreferences-backed last-known server score cache (twin of GRDB serverScoreCache). */
class ServerScoreCacheStore(context: Context) {
    private val prefs = com.noop.account.AccountStorageContext.capture(context)
        .getSharedPreferences("noop_server_score_cache", Context.MODE_PRIVATE)

    fun upsert(cache: ServerScoreDayCache) {
        val json = JSONObject()
            .put("algorithmVersion", cache.algorithmVersion)
            .put("daily", cache.daily?.toJson())
            .put("nights", JSONArray(cache.nights.map { it.toJson() }))
            .put("computedAt", cache.computedAt)
            .put("stale", cache.stale)
            .put("fetchedAtMs", cache.fetchedAtMs)
        prefs.edit().putString(cache.day, json.toString()).apply()
    }

    fun load(day: String): ServerScoreDayCache? {
        val raw = prefs.getString(day, null) ?: return null
        return runCatching { decode(day, JSONObject(raw)) }.getOrNull()
    }

    private fun decode(day: String, o: JSONObject): ServerScoreDayCache {
        val daily = o.optJSONObject("daily")?.let { d ->
            ServerScoreDailyCache(
                hrvRmssdMs = d.optNullableDouble("hrvRmssdMs"),
                restingHrBpm = d.optNullableInt("restingHrBpm"),
                sleepTotalMin = d.optNullableDouble("sleepTotalMin"),
                sleepInBedMin = d.optNullableDouble("sleepInBedMin"),
                sleepAwakeMin = d.optNullableDouble("sleepAwakeMin"),
                sleepLightMin = d.optNullableDouble("sleepLightMin"),
                sleepDeepMin = d.optNullableDouble("sleepDeepMin"),
                sleepRemMin = d.optNullableDouble("sleepRemMin"),
                sleepEfficiency = d.optNullableDouble("sleepEfficiency"),
                respRateBpm = d.optNullableDouble("respRateBpm"),
                computedAt = d.optString("computedAt").takeIf { it.isNotBlank() },
            )
        }
        val nightsArr = o.optJSONArray("nights") ?: JSONArray()
        val nights = buildList {
            for (i in 0 until nightsArr.length()) {
                val n = nightsArr.getJSONObject(i)
                add(
                    ServerScoreNightCache(
                        id = n.getString("id"),
                        startAt = n.getString("startAt"),
                        endAt = n.getString("endAt"),
                        isNap = n.getBoolean("isNap"),
                        asleepMin = n.optNullableDouble("asleepMin"),
                        inBedMin = n.optNullableDouble("inBedMin"),
                        lightMin = n.optNullableDouble("lightMin"),
                        deepMin = n.optNullableDouble("deepMin"),
                        remMin = n.optNullableDouble("remMin"),
                        awakeMin = n.optNullableDouble("awakeMin"),
                        efficiency = n.optNullableDouble("efficiency"),
                        hrvRmssdMs = n.optNullableDouble("hrvRmssdMs"),
                        restingHrBpm = n.optNullableInt("restingHrBpm"),
                    ),
                )
            }
        }
        return ServerScoreDayCache(
            day = day,
            algorithmVersion = o.getString("algorithmVersion"),
            daily = daily,
            nights = nights,
            computedAt = o.optString("computedAt").takeIf { it.isNotBlank() },
            stale = o.optBoolean("stale", true),
            fetchedAtMs = o.getLong("fetchedAtMs"),
        )
    }

    private fun ServerScoreDailyCache.toJson(): JSONObject = JSONObject()
        .put("hrvRmssdMs", hrvRmssdMs)
        .put("restingHrBpm", restingHrBpm)
        .put("sleepTotalMin", sleepTotalMin)
        .put("sleepInBedMin", sleepInBedMin)
        .put("sleepAwakeMin", sleepAwakeMin)
        .put("sleepLightMin", sleepLightMin)
        .put("sleepDeepMin", sleepDeepMin)
        .put("sleepRemMin", sleepRemMin)
        .put("sleepEfficiency", sleepEfficiency)
        .put("respRateBpm", respRateBpm)
        .put("computedAt", computedAt)

    private fun ServerScoreNightCache.toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("startAt", startAt)
        .put("endAt", endAt)
        .put("isNap", isNap)
        .put("asleepMin", asleepMin)
        .put("inBedMin", inBedMin)
        .put("lightMin", lightMin)
        .put("deepMin", deepMin)
        .put("remMin", remMin)
        .put("awakeMin", awakeMin)
        .put("efficiency", efficiency)
        .put("hrvRmssdMs", hrvRmssdMs)
        .put("restingHrBpm", restingHrBpm)

    private fun JSONObject.optNullableDouble(key: String): Double? =
        if (!has(key) || isNull(key)) null else getDouble(key)

    private fun JSONObject.optNullableInt(key: String): Int? =
        if (!has(key) || isNull(key)) null else getInt(key)
}
