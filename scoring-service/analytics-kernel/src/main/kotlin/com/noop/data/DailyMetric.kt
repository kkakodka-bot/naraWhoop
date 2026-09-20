package com.noop.data

/**
 * Plain-JVM DTO twin of the Room entity in `android/app/src/main/java/com/noop/data/Entities.kt`.
 * Field names, types, order, and defaults are byte-verbatim; Room annotations are dropped (inert).
 * `DtoParityTest` diffs this field list against `Entities.kt` mechanically — do not rename, retype,
 * reorder, or "improve" anything here.
 */
data class DailyMetric(
    val deviceId: String,
    val day: String,
    val totalSleepMin: Double? = null,
    val efficiency: Double? = null,
    val deepMin: Double? = null,
    val remMin: Double? = null,
    val lightMin: Double? = null,
    val disturbances: Int? = null,
    val restingHr: Int? = null,
    val avgHrv: Double? = null,
    val recovery: Double? = null,
    val strain: Double? = null,
    val exerciseCount: Int? = null,
    val spo2Pct: Double? = null,
    val skinTempDevC: Double? = null,
    val respRateBpm: Double? = null,
    val steps: Int? = null,
    val activeKcalEst: Double? = null,
    val spo2Red: Int? = null,
    val spo2Ir: Int? = null,
    val avgSdnn: Double? = null,
    val skinTempC: Double? = null,
    val sleepHrOnly: Boolean? = null,
)
