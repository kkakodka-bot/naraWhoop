package com.frwhoop.scoring

import com.frwhoop.scoring.scoring.SleepBoundaryOverride
import com.frwhoop.scoring.scoring.SleepBoundaryOverrides
import com.noop.analytics.DetectedSleep
import com.noop.analytics.SleepStageSemantics
import com.noop.analytics.StageSegment
import org.junit.Assert.*
import org.junit.Test

class SleepBoundaryOverridesTest {
    private fun sleep(start:Long,end:Long)=DetectedSleep(start,end,1.0,
        listOf(StageSegment(start,end,"deep")),null,null)
    private fun edit(start:Long=120,end:Long=660,tombstone:Boolean=false)=SleepBoundaryOverride(
        "manual-id",0,600,start,end,tombstone,1,"user_annotation")

    @Test fun movedBoundsClipTruthAndAddUnknownInsteadOfSleep() {
        val out=SleepBoundaryOverrides.apply(listOf(sleep(0,600)),listOf(edit())).single()
        assertEquals(120,out.start);assertEquals(660,out.end)
        assertEquals(2,out.stages.size)
        assertEquals("deep",out.stages.first().stage)
        assertEquals("state_unknown",out.stages.last().state)
        assertTrue(out.boundaryProvenance!!.startsWith("user_boundary:"))
    }
    @Test fun tombstoneSurvivesLateDataAndDoesNotRemoveSeparateNap() {
        val edits=listOf(edit(tombstone=true))
        for (candidate in listOf(sleep(0,600),sleep(30,620))) {
            val out=SleepBoundaryOverrides.apply(listOf(candidate,sleep(1000,1300)),edits)
            assertEquals(listOf(1000L),out.map { it.start })
        }
    }
    @Test fun boundaryWithoutSignalIsUnknownAndReplayDoesNotAccumulate() {
        val first=SleepBoundaryOverrides.apply(emptyList(),listOf(edit()))
        assertTrue(first.single().stages.none(SleepStageSemantics::isKnownState))
        assertEquals(first,SleepBoundaryOverrides.apply(first,listOf(edit())))
    }
    @Test fun movingAwayRemovesBothOriginalAndConflictingGeneratedDestination() {
        val result=SleepBoundaryOverrides.apply(listOf(sleep(0,600),sleep(1000,1500)),
            listOf(edit(start=1100,end=1400)))
        assertEquals(1,result.size);assertEquals(1100,result.single().start)
    }
    @Test fun movingThenDeletingSuppressesLateDataAtBothOriginalAndEditedBounds() {
        val tombstone=edit(start=1100,end=1400,tombstone=true).copy(revision=2)
        val late=listOf(sleep(0,600),sleep(1000,1500),sleep(2000,2600))
        val result=SleepBoundaryOverrides.apply(late,listOf(tombstone))
        assertEquals(listOf(2000L),result.map { it.start })
        assertEquals(result,SleepBoundaryOverrides.apply(result,listOf(tombstone)))
    }
}
