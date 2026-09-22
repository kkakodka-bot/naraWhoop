package com.noop.data

/**
 * Plain-JVM DTO twin of the Room entity in `android/app/src/main/java/com/noop/data/Entities.kt`.
 * Field names, types, order, and defaults are byte-verbatim; Room annotations are dropped (inert).
 * `DtoParityTest` diffs this field list against `Entities.kt` mechanically — do not rename, retype,
 * reorder, or "improve" anything here.
 */
data class Spo2Sample(
    val deviceId: String,
    val ts: Long,
    val red: Int,
    val ir: Int,
    val synced: Int = 0,
)
