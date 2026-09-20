package com.frwhoop.scoring

import com.frwhoop.scoring.scoring.PhysiologyMotionEvidence
import com.frwhoop.scoring.db.CanonicalRrPolicy
import com.noop.analytics.PhysiologyQuality
import com.noop.data.GravitySample
import com.noop.data.RrInterval
import com.noop.protocol.DeviceFamily
import org.junit.Assert.*
import org.junit.Test

class PhysiologyMotionEvidenceTest {
    private fun beat()=PhysiologyQuality.IntervalObservation("interval",deviceId="device",source="fixture",eventTime=100.5,
        originalRRMs=800.0,verifiedSpan=PhysiologyQuality.Span(100.5,101.3))
    private fun sample(time:Long,value:Double?)=GravitySample("device",time,0.0,0.0,1.0,dynAccel=value)
    @Test fun missingMotionIsNotCleanAndKnownMotionRejectsEvenWithGap() {
        assertNull(PhysiologyMotionEvidence(listOf(sample(100,.01)),emptyList()).annotate(beat()).motionContaminated)
        assertEquals(true,PhysiologyMotionEvidence(listOf(sample(100,.1)),emptyList()).annotate(beat()).motionContaminated)
        assertEquals(false,PhysiologyMotionEvidence(listOf(sample(100,.01),sample(101,.01)),emptyList()).annotate(beat()).motionContaminated)
    }
    @Test fun conflictingDuplicatesAndImpossibleValuesDoNotCreateMotionCoverage() {
        for(samples in listOf(listOf(sample(100,.01),sample(100,.1)),listOf(sample(100,Double.NaN)),listOf(sample(100,9.0)))) {
            val evidence=PhysiologyMotionEvidence(samples,emptyList())
            assertNull(evidence.annotate(beat()).motionContaminated); assertTrue(evidence.respiratorySpans(0,300).isEmpty())
        }
    }
    @Test fun priorOffBodyContextIsClippedWithoutInventingMotionCoverage() {
        val evidence=PhysiologyMotionEvidence(listOf(sample(99,.01),sample(120,.01)),listOf(0L to 110L,200L to 400L))
        val spans=evidence.respiratorySpans(100,300)
        assertEquals(listOf(120.0 to 121.0,100.0 to 110.0,200.0 to 300.0),spans.map { it.start to it.end })
        assertEquals(1,spans.count { it.contamination.motionObservedFraction==1.0 })
    }
    @Test fun offBodyMarksRejectedContactButAbsenceDoesNotVerifyContact() {
        assertEquals(false,PhysiologyMotionEvidence(emptyList(),listOf(101L to 102L)).annotate(beat()).contactAccepted)
        assertNull(PhysiologyMotionEvidence(emptyList(),emptyList()).annotate(beat()).contactAccepted)
    }
    @Test fun sourceCandidatesAreNotSelectedNightGloballyOrDiscardedWithinWindow() {
        val rows=listOf(RrInterval("device",0,800,0,srcChannel=5),RrInterval("device",10,800,1,srcChannel=7),
            RrInterval("device",300,800,2,srcChannel=7))
        assertEquals(rows,CanonicalRrPolicy.candidates(rows,DeviceFamily.WHOOP5))
    }
}
