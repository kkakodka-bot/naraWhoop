package com.frwhoop.scoring.db

import com.noop.data.RrInterval
import com.noop.protocol.DeviceFamily
import com.noop.protocol.RrSourceChannel

/** Transport filtering is not timing qualification. HRV selects among these candidates per window. */
object CanonicalRrPolicy {
    const val VERSION = "whoop-canonical-rr-2"
    const val TIMESTAMP_PRECISION_SECONDS = 1.0

    fun candidates(rows: List<RrInterval>, family: DeviceFamily): List<RrInterval> = ordered(
        rows.filter { it.tsSuspect != 1 && it.srcChannel != RrSourceChannel.SPO2_IBI.code }
            .groupBy { Math.floorDiv(it.ts, 300L) }.values.flatMap { window ->
                if (family != DeviceFamily.WHOOP5) window
                else {
                    val tagged = window.filter { it.srcChannel == 5 || it.srcChannel == 7 }
                    if (tagged.isNotEmpty()) tagged
                    else if (window.any { it.srcChannel != null && it.srcChannel != 0 }) emptyList()
                    else window
                }
            })

    fun select(rows: List<RrInterval>, family: DeviceFamily): List<RrInterval> {
        val eligible = rows.filter { it.tsSuspect != 1 && it.srcChannel != RrSourceChannel.SPO2_IBI.code }
        if (family != DeviceFamily.WHOOP5) return ordered(eligible)
        val tagged = eligible.filter { it.srcChannel == 5 || it.srcChannel == 7 }
        if (tagged.isNotEmpty()) {
            val source = tagged.mapNotNull { it.srcChannel }.minOrNull()!!
            return ordered(eligible.filter { it.srcChannel == source })
        }
        // Native SQLite keeps untagged WHOOP 5 rows unread so mixed-unit aliases cannot enter HRV.
        // Hosted projections store that same millisecond train as srcChannel 0 (JSON null coerced
        // on some senders) or NULL. Score it only when no other labelled channel is in the window.
        if (eligible.any { channel ->
                val src = channel.srcChannel
                src != null && src != 0
            }) {
            return emptyList()
        }
        return ordered(eligible.filter { it.srcChannel == null || it.srcChannel == 0 })
    }

    private fun ordered(rows: List<RrInterval>): List<RrInterval> =
        rows.sortedWith(compareBy<RrInterval> { it.ts }
            .thenBy(nullsFirst()) { it.ord }.thenBy { it.rrMs }.thenBy { it.seq })
}
