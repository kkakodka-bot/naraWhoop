package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.GravitySample

/** Five-minute sampled HR; the low-motion estimate is separate from the overnight resting baseline. */
object HeartRateWindows {
    const val VERSION = "sampled-hr-five-minute-2"
    data class Measurement(val start: Long, val end: Long, val meanBpm: Double?, val lowMotionBpm: Double?,
                           val sampleFraction: Double, val lowMotionSampleFraction: Double,
                           val reason: String?, val lowMotionReason: String?, val movingSeconds: Int = 0,
                           val motionObservedSeconds: Int = 0)

    /** Caller scopes inputs to one device. Duplicated/conflicting timestamps cannot create coverage. */
    fun windows(start: Long, end: Long, hr: List<HrSample>, gravity: List<GravitySample>,
                excluded: List<Pair<Long,Long>> = emptyList()): List<Measurement> {
        if (end < start || end-start > 172800) return emptyList()
        val first = Math.floorDiv(start+299,300)*300
        val h = hr.filter { it.ts >= first && it.ts < end }.groupBy { it.ts }
        val g = gravity.filter { it.ts >= first && it.ts < end }.groupBy { it.ts }
        val output = mutableListOf<Measurement>()
        var t = first
        while (t+300 <= end) {
            val values = mutableListOf<Double>(); val quietValues = mutableListOf<Double>()
            var gap=0; var longestGap=0; var quietGap=0; var longestQuietGap=0
            var offBody=false; var movingSeconds=0; var motionObservedSeconds=0
            for (second in t until t+300) {
                val excludedSecond = excluded.any { it.first < second+1 && it.second > second }
                offBody = offBody || excludedSecond
                val hrs = h[second].orEmpty().map { it.bpm }.toSet()
                val value = hrs.singleOrNull()?.takeIf { !excludedSecond && it in 25..240 }?.toDouble()
                val gs = g[second].orEmpty()
                val motion = gs.mapNotNull { it.dynAccel }.filter { it.isFinite() && it in 0.0..8.0 }.toSet()
                // Room stores dynamic acceleration in g; Swift's protocol DTO also carries its unit.
                val validMotion = gs.isNotEmpty() && gs.all { it.dynAccel?.let { a -> a.isFinite() && a in 0.0..8.0 } == true } && motion.size == 1
                val moving = validMotion && motion.single() > .03
                if (validMotion) motionObservedSeconds++
                if (moving) movingSeconds++
                if (value != null) { values.add(value); gap=0 } else gap++
                if (value != null && validMotion && !moving) { quietValues.add(value); quietGap=0 } else quietGap++
                longestGap=maxOf(longestGap,gap); longestQuietGap=maxOf(longestQuietGap,quietGap)
            }
            val fraction=values.size/300.0; val quietFraction=quietValues.size/300.0
            val reason=when { fraction<.9 -> "insufficient_hr_samples"; longestGap>30 -> "hr_sample_gap"; else -> null }
            val quietReason=when { offBody -> "off_body_evidence"
                quietFraction<.9 -> "insufficient_motion_matched_samples"; longestQuietGap>30 -> "motion_sample_gap"; else -> null }
            output.add(Measurement(t,t+300,if(reason==null) values.average() else null,
                if(quietReason==null) quietValues.average() else null,fraction,quietFraction,reason,quietReason,
                movingSeconds,motionObservedSeconds))
            t+=300
        }
        return output
    }
}
