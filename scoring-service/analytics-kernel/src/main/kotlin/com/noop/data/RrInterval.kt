package com.noop.data

/**
 * Plain-JVM DTO twin of the Room entity in `android/app/src/main/java/com/noop/data/Entities.kt`.
 * Field names, types, order, and defaults are byte-verbatim; Room annotations are dropped (inert).
 * `DtoParityTest` diffs this field list against `Entities.kt` mechanically — do not rename, retype,
 * reorder, or "improve" anything here.
 */
data class RrInterval(
    val deviceId: String,
    val ts: Long,
    val rrMs: Int,
    val seq: Int = 0,
    val synced: Int = 0,
    val ord: Int? = null,
    val srcChannel: Int? = null,
    val tsSuspect: Int? = null,
)
