package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.signals.PhysiologyShadowRunner
import com.noop.analytics.HeartRateWindows
import com.noop.analytics.SleepContextSpan
import com.noop.analytics.SleepStageSemantics
import com.noop.analytics.StageSegment

/** Context qualification does not establish usable beat timing or respiratory modulation. */
internal object RespirationContexts {
    fun withAwakeRest(
        sleep: List<PhysiologyShadowRunner.Context>,
        heartRateWindows: List<HeartRateWindows.Measurement>,
        stages: List<StageSegment>,
        annotations: List<SleepContextSpan>,
    ): List<PhysiologyShadowRunner.Context> {
        val awake = annotations.filter { it.kind in setOf("awake", "reading", "phone_use") }
            .map { it.start to it.end } + stages.filter {
                it.state == "awake" && SleepStageSemantics.isKnownState(it)
            }.map { it.start to it.end }
        val blocked = annotations.filter { it.kind in setOf("off_body", "sleep") }
            .map { it.start to it.end } + stages.filter {
                it.state != "awake" || !SleepStageSemantics.isKnownState(it)
            }.map { it.start to it.end }
        val orderedAwake = awake.filter { it.second > it.first }.sortedBy { it.first }
        fun fullyAwake(start: Long, end: Long): Boolean {
            var through = start
            for ((lo, hi) in orderedAwake) {
                if (hi <= through) continue
                if (lo > through) return false
                through = hi
                if (through >= end) return true
            }
            return false
        }
        val rest = heartRateWindows.filter { window ->
            // Reuse the existing sampled-HR/motion quality policy; a quiet accelerometer alone
            // must not turn an unknown sleep/wake interval into awake rest.
            window.lowMotionBpm != null && window.movingSeconds == 0 && window.motionObservedSeconds == 300 &&
                fullyAwake(window.start, window.end) &&
                blocked.none { it.first < window.end && it.second > window.start } &&
                sleep.none { it.start < window.end && it.end > window.start }
        }.map { PhysiologyShadowRunner.Context(it.start.toDouble(), it.end.toDouble(), "qualified_awake_rest") }
        val result = mutableListOf<PhysiologyShadowRunner.Context>()
        for (context in (sleep + rest).sortedBy { it.start }) {
            val previous = result.lastOrNull()
            if (previous != null && previous.kind == context.kind && previous.end == context.start) {
                result[result.lastIndex] = previous.copy(end = context.end)
            } else result += context
        }
        return result
    }
}
