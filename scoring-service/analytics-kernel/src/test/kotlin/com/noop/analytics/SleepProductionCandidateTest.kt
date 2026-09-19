package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.sin

class SleepProductionCandidateTest {
    private fun session(start: Long,span: Long,accepted: Long)=DetectedSleep(start,start+span,accepted.toDouble()/span,
        listOf(StageSegment(start,start+accepted,"unknown",state="sleep_unstaged")),null,null)

    @Test fun acceptedDurationWinsOverClockAndOuterSpan() {
        for(offset in listOf(0L,7*3600L,-8*3600L)) {
            val sessions=listOf(session(3600,8*3600,2*3600),session(13*3600,3*3600,3*3600))
            assertEquals(listOf(1),SleepOpportunityDetector.mainSleepGroupIndices(sessions,offset))
            assertEquals(listOf(1),SleepOpportunityDetector.mainSleepGroupIndices(sessions,offset,12600))
        }
        assertEquals(listOf(0,1),SleepOpportunityDetector.mainSleepGroupIndices(
            listOf(session(8*3600,3600,3600),session(9*3600+1800,3600,3600)),0))
    }

    @Test fun binarySleepSurvivesStagerWakeAndMainSelection() {
        val disagreement=StageSegment(0,7200,"wake",state="sleep")
        assertTrue(SleepStageSemantics.isSleep(disagreement))
        assertTrue(SleepStageSemantics.isKnownState(StageSegment(0,30,"unknown",state="awake")))
        assertEquals(listOf(0),SleepOpportunityDetector.mainSleepGroupIndices(
            listOf(DetectedSleep(0,7200,1.0,listOf(disagreement),null,null)),0))
        val staged=SleepOpportunityDetector.stagesPreservingBinarySleep(
            listOf(StageSegment(0,7200,"wake",state="awake")),0,7200)
        assertTrue(staged.all { it.stage=="unknown" && it.state=="sleep_unstaged" && it.abstentionReason=="stage_binary_disagreement" })
        val binary=DetectedSleep(0,7200,1.0,staged,null,null)
        assertEquals(7200L,SleepOpportunityDetector.acceptedSleepSeconds(binary))
        assertEquals(listOf(0),SleepOpportunityDetector.mainSleepGroupIndices(listOf(binary),0))
    }

    @Test fun napOtherAndUncertainRemainDistinct() {
        assertEquals("nap",SleepOpportunityDetector.episodeType(session(0,1200,1200),false))
        assertEquals("other_sleep",SleepOpportunityDetector.episodeType(session(0,14400,14400),false))
        assertEquals("other_sleep",SleepOpportunityDetector.episodeType(session(0,14400,1200),false))
        assertEquals("uncertain",SleepOpportunityDetector.episodeType(session(0,61200,61200),true))
    }

    @Test fun impossibleGravityAndSingleModalityCannotStage() {
        val hr=(0L until 600).map { HrSample("device",it,55+(it%2).toInt()) }
        val real=hr.map { GravitySample("device",it.ts,0.0,0.0,1.0) }
        for(g in listOf(emptyList(),real,hr.map { GravitySample("device",it.ts,100.0,0.0,0.0) })) {
            val staged=SleepStagerV2.stageSession(0,600,g,if(g==real) emptyList() else hr,emptyList(),emptyList())
            assertTrue(staged.all { it.state=="state_unknown" })
        }
        assertTrue(SleepStagerV2.stageSession(0,600,real,hr,emptyList(),emptyList()).any { it.stage!="unknown" })
    }

    @Test fun frozenStreamsAndOverlongEpisodesBecomeUnknown() {
        val hr=(0L until 86400 step 5).map { HrSample("device",it,if(it<17*3600) 55 else 80) }
        val frozen=SleepOpportunityDetector.detect(0,86400,hr,hr.map { GravitySample("device",it.ts,0.0,0.0,1.0) })
        assertTrue(frozen.episodes.isEmpty())
        assertTrue(frozen.epochs.any { it.abstentionReason=="sensor_stale_or_constant" })
        val long=SleepOpportunityDetector.detect(0,86400,hr,hr.map { GravitySample("device",it.ts,0.00001*sin(it.ts.toDouble()),0.0,1.0) })
        assertTrue(long.episodes.isEmpty())
        assertTrue(long.epochs.any { it.abstentionReason=="episode_exceeds_supported_duration" })
        assertFalse(long.epochs.any(SleepStageSemantics::isSleep))
    }

    @Test fun stagingRejectsFrozenStreamsAndFindsOffsetAcquisitionClocks() {
        val hr=(0L until 2700).map { HrSample("device",it,55) }
        val gravity=hr.map { GravitySample("device",it.ts,0.0,0.0,1.0) }
        val shifted=gravity.map { it.copy(ts=it.ts+2) }
        assertEquals(listOf(2L until 2700),SleepSignalValidity.constantSensorSpans(hr,shifted,1800))
        val staged=SleepStagerV2.stageSession(0,2700,gravity,hr,emptyList(),emptyList())
        assertTrue(staged.all { it.stage=="unknown" && it.abstentionReason=="sensor_stale_or_constant" })
        val long=SleepStagerV2.stageSession(0,17*3600,emptyList(),emptyList(),emptyList(),emptyList())
        assertTrue(long.all { it.stage=="unknown" && it.abstentionReason=="episode_exceeds_supported_duration" })
    }

    @Test fun fullDayContextSurvivesWithoutAnEpisodeAndRoundTrips() {
        val day=AnalyticsEngine.dayStartUtcSeconds("2026-09-17")
        val context=listOf("reading","phone_use","quiet_rest","off_body","sleep_opportunity").mapIndexed { i,kind ->
            SleepContextSpan(day+i*1800,day+(i+1)*1800,kind,"user_report") }
        val result=AnalyticsEngine.analyzeDay(day="2026-09-17",profile=UserProfile(),sleepContext=context,useFullDaySleepOpportunities=true)
        assertTrue(result.sleepSessions.isEmpty())
        assertEquals(86400L,result.fullDaySleepEpochs.sumOf { it.end-it.start })
        for(c in context) {
            val epoch=result.fullDaySleepEpochs.first { it.start==c.start }
            assertEquals(c.kind,epoch.contextKind); assertEquals("user_report",epoch.contextProvenance)
            assertFalse(SleepStageSemantics.isSleep(epoch))
        }
        assertEquals(result.fullDaySleepEpochs,AnalyticsEngine.decodeStages(AnalyticsEngine.encodeStages(result.fullDaySleepEpochs)!!))
    }
}
