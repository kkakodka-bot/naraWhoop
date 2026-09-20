package com.frwhoop.scoring.scoring

import java.util.UUID

/** The raw detected key and durable edit entity survive bounds, timezone/day and algorithm changes. */
data class SleepIdentity(val originalStart: Long, val originalEnd: Long, val editEntity: String) {
    init {
        require(originalStart > 0 && originalEnd > originalStart)
        require(editEntity.startsWith("sleep:"))
        require(UUID.fromString(editEntity.removePrefix("sleep:")).toString() == editEntity.removePrefix("sleep:"))
    }

    val id: String get() = editEntity.removePrefix("sleep:")

    companion object {
        fun detected(userId: UUID, deviceId: String, start: Long, end: Long): SleepIdentity {
            val id = UUID.nameUUIDFromBytes("sleep-v1|$userId|$deviceId|$start".toByteArray(Charsets.UTF_8))
            return SleepIdentity(start, end, "sleep:$id")
        }
    }
}

/** Exact output bounds key: avoids matching an edit to a neighboring session by start alone. */
data class SleepBounds(val start: Long, val end: Long)
