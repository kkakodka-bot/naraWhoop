package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.StepSample
import kotlin.math.sqrt

/** Shared engineering input domain; rejected raw samples remain in storage, never feature coverage. */
object SleepSignalValidity {
    fun heartRate(sample: HrSample): Boolean = sample.bpm in 25..240
    fun gravity(sample: GravitySample): Boolean {
        val magnitudeSquared = sample.x * sample.x + sample.y * sample.y + sample.z * sample.z
        val vectorOk = sample.x.isFinite() && sample.y.isFinite() && sample.z.isFinite() &&
            magnitudeSquared.isFinite() && magnitudeSquared > 1e-12
        val dyn = sample.dynAccel
        val dynOk = dyn != null && dyn.isFinite() && dyn in 0.0..8.0
        // WHOOP 5 live projections often bank a 1 Hz zero vector plus the strap's own dynAccel.
        // A zero placeholder is not motion evidence; dynAccel in-gate still is.
        return vectorOk || dynOk
    }
    fun orientationMagnitudeSquared(sample: GravitySample): Double =
        sample.x * sample.x + sample.y * sample.y + sample.z * sample.z
    fun hasOrientation(sample: GravitySample): Boolean {
        val magnitudeSquared = orientationMagnitudeSquared(sample)
        return sample.x.isFinite() && sample.y.isFinite() && sample.z.isFinite() &&
            magnitudeSquared.isFinite() && magnitudeSquared > 1e-12
    }
    fun movement(samples: List<GravitySample>): Double? {
        val unit = samples.filter(::hasOrientation).map {
            val norm = sqrt(orientationMagnitudeSquared(it))
            doubleArrayOf(it.x / norm, it.y / norm, it.z / norm)
        }
        val orientation = unit.zipWithNext().map { (a, b) ->
            sqrt(a.indices.sumOf { (a[it] - b[it]) * (a[it] - b[it]) })
        }.takeIf { it.isNotEmpty() }?.average()
        if (orientation != null) return orientation
        return samples.mapNotNull { it.dynAccel }.filter { it.isFinite() && it in 0.0..8.0 }
            .takeIf { it.isNotEmpty() }?.average()
    }
}

/** Full-day binary candidate detector. Engineering shadow policy, not calibrated sleep truth. */
object SleepOpportunityDetector {
    const val VERSION = "full-day-binary-shadow-1"
    const val MINIMUM_MAIN_SLEEP_SECONDS = 90 * 60L // Engineering grouping rule, independent of bedtime.
    data class Policy(val minimumSleepSeconds: Long = 15 * 60, val minimumFeatureBinCoverage: Double = 5.0 / 6,
                      val maximumRelativeHr: Double = 0.9, val maximumRelativeHrWithoutOrientation: Double = 0.85,
                      val maximumMeanOrientationChange: Double = 0.03)
    data class Result(val epochs: List<StageSegment>, val episodes: List<DetectedSleep>, val referenceHr: Double?)

    /** Qualify complete groups before ranking so an ineligible nap cannot hide eligible main sleep. */
    fun mainSleepGroupIndices(sessions: List<DetectedSleep>, offsetSeconds: Long,
                              habitualMidsleepSec: Long? = null): List<Int> {
        val candidates = sessions.indices.filter { sessions[it].hasKnownState }
        val blocks = candidates.map { SleepStageTotals.NightBlock(sessions[it].start, sessions[it].end) }
        val groups = SleepStageTotals.bridgedNightGroups(blocks, offsetSeconds).map { group ->
            group.indices.map { candidates[it] }
        }.filter { group ->
            group.sumOf { i -> SleepStageSemantics.normalized(sessions[i].stages, sessions[i].start, sessions[i].end)
                .filter(SleepStageSemantics::isSleep).sumOf { it.end - it.start } } >= MINIMUM_MAIN_SLEEP_SECONDS
        }
        val spans = groups.map { group -> SleepStageTotals.NightBlock(
            group.minOf { sessions[it].start }, group.maxOf { sessions[it].end }) }
        val winner = SleepStageTotals.mainNightIndex(spans, offsetSeconds, habitualMidsleepSec) ?: return emptyList()
        return groups[winner]
    }

    /** No clock-of-day gate. Missing HR/motion and ambiguous stillness remain unknown, not sleep. */
    fun detect(start: Long, end: Long, hr: List<HrSample>, gravity: List<GravitySample>,
               steps: List<StepSample> = emptyList(), context: List<SleepContextSpan> = emptyList(),
               policy: Policy = Policy()): Result {
        require(end > start && end - start <= 76 * 3600 && policy.minimumSleepSeconds in 300..14400)
        require(policy.minimumFeatureBinCoverage in 0.5..1.0 && policy.maximumRelativeHr in 0.5..0.99 &&
            policy.maximumRelativeHrWithoutOrientation in 0.5..0.99 &&
            policy.maximumMeanOrientationChange in 0.001..0.2)
        val h = hr.filter { it.ts in start until end && SleepSignalValidity.heartRate(it) }.distinctBy { it.ts }.sortedBy { it.ts }
        val g = gravity.filter { it.ts in start until end && SleepSignalValidity.gravity(it) }.distinctBy { it.ts }.sortedBy { it.ts }
        // Per-minute medians prevent dense bursts from dominating the retrospective reference.
        val reference = h.groupBy { Math.floorDiv(it.ts,60) }.values.map { rows ->
            rows.map { it.bpm }.sorted().let { (it[(it.size-1)/2]+it[it.size/2])/2.0 }
        }.sorted().takeIf { it.size >= 60 }?.let { it[((it.size-1)*0.75).toInt()] }
        val hrEpochs=h.groupBy { Math.floorDiv(it.ts,30)*30 }
        val gravityEpochs=g.groupBy { Math.floorDiv(it.ts,30)*30 }
        val moving = steps.filter { it.ts in (start-10) until end }.sortedBy { it.ts }.zipWithNext()
            .filter { (a,b) -> b.ts-a.ts in 1..10 && b.counter>a.counter }.map { Math.floorDiv(it.second.ts,30)*30 }.toSet()
        val epochs=mutableListOf<StageSegment>()
        var t=Math.floorDiv(start+29,30)*30
        while(t+30<=end) {
            val rows=hrEpochs[t].orEmpty(); val motion=gravityEpochs[t].orEmpty()
            // Fraction of six sampled 5-second feature bins, NOT continuous beat-observation coverage.
            val coverage=minOf(rows.map { Math.floorDiv(it.ts-t,5) }.distinct().size,
                motion.map { Math.floorDiv(it.ts-t,5) }.distinct().size)/6.0
            val annotations=context.filter { it.start<t+30 && it.end>t }
            val offBody=annotations.any { it.kind=="off_body" }
            val awake=annotations.any { it.kind in listOf("awake","reading","phone_use") }
            val movement=SleepSignalValidity.movement(motion)
            val relativeHr=if (motion.count(SleepSignalValidity::hasOrientation) >= 2)
                policy.maximumRelativeHr else policy.maximumRelativeHrWithoutOrientation
            val state=when {
                offBody -> "off_body"
                awake || t in moving -> "awake"
                coverage<policy.minimumFeatureBinCoverage || movement==null -> "state_unknown"
                movement>policy.maximumMeanOrientationChange -> "awake"
                reference!=null && rows.map { it.bpm }.average()<=reference*relativeHr -> "sleep_unstaged"
                else -> "state_unknown"
            }
            val reason=when(state) {
                "off_body" -> "off_body_context"
                "awake" -> if(awake) "awake_behavior_context" else "observed_motion"
                "sleep_unstaged" -> "uncalibrated_hr_motion_candidate"
                else -> if(coverage<policy.minimumFeatureBinCoverage) "missing_hr_motion_features" else "quiet_wake_or_sleep_uncertain"
            }
            epochs+=StageSegment(t,t+30,if(state=="awake") "wake" else "unknown",state=state,
                evidenceCoverage=coverage,abstentionReason=reason,computationMode="retrospective",
                algorithmVersion=VERSION,probabilitiesCalibrated=false)
            t+=30
        }
        val episodes=mutableListOf<DetectedSleep>(); var run=mutableListOf<StageSegment>()
        fun finish() {
            if(run.isNotEmpty() && run.last().end-run.first().start>=policy.minimumSleepSeconds) {
                episodes+=DetectedSleep(run.first().start,run.last().end,1.0,run.toList(),
                    SleepStager.sessionRestingHR(run.first().start,run.last().end,h),null,
                    boundaryProvenance="algorithm_estimated_shadow",denominatorKind="estimated_sleep_opportunity")
            }
            run=mutableListOf()
        }
        for(epoch in epochs) { if(SleepStageSemantics.isSleep(epoch)) run+=epoch else finish() }; finish()
        return Result(epochs,episodes,reference)
    }
}
