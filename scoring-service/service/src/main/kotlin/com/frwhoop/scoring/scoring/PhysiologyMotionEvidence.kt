package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.signals.PhysiologyShadowRunner
import com.noop.analytics.PhysiologyQuality
import com.noop.analytics.RespirationEstimator
import com.noop.data.GravitySample
import kotlin.math.ceil
import kotlin.math.floor

/** Observed one-second dynamic acceleration in g; gaps and conflicting duplicates stay missing. */
internal class PhysiologyMotionEvidence(gravity: List<GravitySample>, private val offBody: List<Pair<Long,Long>>) {
    private val motion = gravity.groupBy { it.ts }.mapNotNull { (second,rows) ->
        val values=rows.map { it.dynAccel }
        if(values.any { it==null || !it.isFinite() || it !in 0.0..8.0 } || values.toSet().size!=1) null
        else second to values.first()!!
    }.toMap()

    fun annotate(row: PhysiologyQuality.IntervalObservation): PhysiologyQuality.IntervalObservation {
        val span=row.verifiedSpan ?: return row
        if(!span.start.isFinite() || !span.end.isFinite() || span.end<=span.start || span.end-span.start>3) return row
        val samples=(floor(span.start).toLong() until ceil(span.end).toLong()).map { motion[it] }
        val moving=when {
            row.motionContaminated==true || samples.any { it!=null && it>.03 } -> true
            samples.isNotEmpty() && samples.all { it!=null } -> false
            else -> row.motionContaminated
        }
        val removed=offBody.any { it.first<span.end && it.second>span.start }
        return row.copy(motionContaminated=moving,contactAccepted=if(removed) false else row.contactAccepted)
    }

    fun respiratorySpans(start: Long,end: Long): List<PhysiologyShadowRunner.ContaminationSpan> = (motion.map { (second,value) ->
        PhysiologyShadowRunner.ContaminationSpan(second.toDouble(),second+1.0,
            RespirationEstimator.Contamination(motionObservedFraction=1.0,motionContaminated=value>.03,
                evidenceVersion="projected-dynamic-acceleration-g-1"))
    } + offBody.map { (start,end) -> PhysiologyShadowRunner.ContaminationSpan(start.toDouble(),end.toDouble(),
        RespirationEstimator.Contamination(signalQualityReasons=listOf("off_body_evidence"),evidenceVersion="wrist-context-1")) })
        .mapNotNull { span ->
            val lo=maxOf(span.start,start.toDouble()); val hi=minOf(span.end,end.toDouble())
            if(hi>lo) span.copy(start=lo,end=hi) else null
        }
}
