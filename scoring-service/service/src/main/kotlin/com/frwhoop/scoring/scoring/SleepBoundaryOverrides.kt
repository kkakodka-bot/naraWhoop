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
            val stages = if(edit.end-edit.start>com.noop.analytics.SleepOpportunityDetector.MAXIMUM_EPISODE_SECONDS)
                listOf(com.noop.analytics.StageSegment(edit.start,edit.end,"unknown",state="state_unknown",
                    abstentionReason="episode_exceeds_supported_duration"))
                else SleepStageSemantics.normalized(evidence,edit.start,edit.end)
            result += DetectedSleep(edit.start,edit.end,
                SleepStager.efficiency(edit.start,edit.end,stages),stages,null,null,
                boundaryProvenance="user_boundary:${edit.provenance}:${edit.id}",
                denominatorKind="user_reported_sleep_opportunity")
        }
        return result.sortedWith(compareBy({ it.start },{ it.end }))
    }

    fun applyToFullDay(epochs: List<com.noop.analytics.StageSegment>, episodes: List<DetectedSleep>,
                       overrides: List<SleepBoundaryOverride>): List<com.noop.analytics.StageSegment> {
        if(overrides.isEmpty()) return epochs
        return epochs.flatMap { epoch ->
            val cuts=(listOf(epoch.start,epoch.end)+overrides.flatMap {
                listOf(it.start,it.end,it.originalStart,it.originalEnd)
            }.filter { it>epoch.start && it<epoch.end }).distinct().sorted()
            cuts.zipWithNext().map { (start,end) ->
                if(overrides.none { start<it.end && end>it.start || start<it.originalEnd && end>it.originalStart })
                    epoch.copy(start=start,end=end)
                else episodes.flatMap { it.stages }.firstOrNull { it.start<=start && it.end>=end }
                    ?.copy(start=start,end=end) ?: epoch.copy(start=start,end=end,stage="unknown",state="state_unknown",
                        abstentionReason="manual_boundary_exclusion",sleepProbability=null,pWake=null,pLight=null,pDeep=null,pRem=null,
                        probabilitiesCalibrated=false)
            }
        }
    }
}
