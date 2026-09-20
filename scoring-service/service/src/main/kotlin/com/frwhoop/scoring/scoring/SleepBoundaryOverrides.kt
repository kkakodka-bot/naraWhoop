package com.frwhoop.scoring.scoring

import com.noop.analytics.DetectedSleep
import com.noop.analytics.SleepStageSemantics
import com.noop.analytics.SleepStager

/** A user-edited opportunity is a boundary constraint, never a physiological sleep label. */
data class SleepBoundaryOverride(
    val id: String,
    val originalStart: Long,
    val originalEnd: Long,
    val start: Long,
    val end: Long,
    val tombstone: Boolean,
    val revision: Long,
    val provenance: String,
) {
    init { require(originalEnd > originalStart && end > start) }
}

/** Reapply edits after each generated episode set, including when the underlying signals vanish. */
object SleepBoundaryOverrides {
    fun apply(generated: List<DetectedSleep>, overrides: List<SleepBoundaryOverride>): List<DetectedSleep> {
        fun overlaps(a: Long, b: Long, c: Long, d: Long) = a < d && c < b
        val result = generated.filter { session -> overrides.none {
            overlaps(session.start,session.end,it.originalStart,it.originalEnd) ||
                overlaps(session.start,session.end,it.start,it.end)
        } }.toMutableList()
        // The reader orders by update time. A newer edit takes priority over an overlapping old
        // imported edit; tombstones suppress machine regeneration regardless of arrival order.
        for (edit in overrides) {
            if (edit.tombstone) continue
            result.removeAll { overlaps(it.start,it.end,edit.start,edit.end) }
            val evidence = generated.filter { overlaps(it.start,it.end,edit.start,edit.end) }
                .flatMap { it.stages }.filter { it.end > edit.start && it.start < edit.end }
            val stages = SleepStageSemantics.normalized(evidence,edit.start,edit.end)
            result += DetectedSleep(edit.start,edit.end,
                SleepStager.efficiency(edit.start,edit.end,stages),stages,null,null,
                boundaryProvenance="user_boundary:${edit.provenance}:${edit.id}",
                denominatorKind="user_reported_sleep_opportunity")
        }
        return result.sortedWith(compareBy({ it.start },{ it.end }))
    }
}
