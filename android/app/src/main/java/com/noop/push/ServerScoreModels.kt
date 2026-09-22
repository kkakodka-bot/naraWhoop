package com.noop.push

data class ServerScoreDailyCache(
    val hrvRmssdMs: Double? = null,
    val restingHrBpm: Int? = null,
    val sleepTotalMin: Double? = null,
    val sleepInBedMin: Double? = null,
    val sleepAwakeMin: Double? = null,
    val sleepLightMin: Double? = null,
    val sleepDeepMin: Double? = null,
    val sleepRemMin: Double? = null,
    val sleepEfficiency: Double? = null,
    val respRateBpm: Double? = null,
    val computedAt: String? = null,
)

data class ServerScoreNightCache(
    val id: String,
    val startAt: String,
    val endAt: String,
    val isNap: Boolean,
    val asleepMin: Double? = null,
    val inBedMin: Double? = null,
    val lightMin: Double? = null,
    val deepMin: Double? = null,
    val remMin: Double? = null,
    val awakeMin: Double? = null,
    val efficiency: Double? = null,
    val hrvRmssdMs: Double? = null,
    val restingHrBpm: Int? = null,
)

data class ServerScoreDayCache(
    val day: String,
    val algorithmVersion: String,
    val daily: ServerScoreDailyCache?,
    val nights: List<ServerScoreNightCache>,
    val computedAt: String?,
    val stale: Boolean,
    val fetchedAtMs: Long,
)
