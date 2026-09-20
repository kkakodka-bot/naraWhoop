package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

class SleepOpportunityDetectorTest {
    private val day=AnalyticsEngine.dayStartUtcSeconds("2026-09-17")
    private val nap=day+15*3600
    private fun hr(sleep: List<LongRange>)=(day until day+86400 step 5).map { t ->
        HrSample("device",t,if(sleep.any { t in it }) 55 else 80)
    }
    private fun gravity()=(day until day+86400 step 5).map { GravitySample("device",it,0.0,0.0,1.0) }

    @Test fun twentyMinuteAfternoonNapAndDaytimeShiftSleepAreCandidatesWithoutTimeOfDayGate() {
        val ranges=listOf(day+8*3600 until day+13*3600,nap until nap+1200)
        val out=SleepOpportunityDetector.detect(day,day+86400,hr(ranges),gravity())
        assertEquals(ranges.map { it.first to it.last+1 },out.episodes.map { it.start to it.end })
        assertTrue(out.episodes.last().stages.all { it.state=="sleep_unstaged" && it.sleepProbability==null })
        assertEquals(80.0,out.referenceHr!!,0.0)
    }
    @Test fun readingPhoneUseAndOffBodyAreNotShortNapsAndStillnessAloneIsUnknown() {
        for(kind in listOf("reading","phone_use","off_body")) {
            val out=SleepOpportunityDetector.detect(day,day+86400,hr(listOf(nap until nap+1200)),gravity(),
                context=listOf(SleepContextSpan(nap,nap+1200,kind,"independent_annotation")))
            assertTrue(out.episodes.isEmpty())
            assertEquals(if(kind=="off_body") "off_body" else "awake",out.epochs.first { it.start==nap }.state)
        }
        assertTrue(SleepOpportunityDetector.detect(day,day+86400,hr(emptyList()),gravity()).episodes.isEmpty())
    }
    @Test fun missingMotionBreaksTheRunAndDuplicateBurstCannotInventCoverage() {
        val low=hr(listOf(nap until nap+1200))
        assertTrue(SleepOpportunityDetector.detect(day,day+86400,low,emptyList()).episodes.isEmpty())
        val gap=gravity().filterNot { it.ts in nap+300 until nap+900 }
        assertTrue(SleepOpportunityDetector.detect(day,day+86400,low,gap).episodes.isEmpty())
        val burst=List(100) { GravitySample("device",nap,0.0,0.0,1.0) }
        assertTrue(SleepOpportunityDetector.detect(day,day+86400,low,burst).episodes.isEmpty())
        val dynStill=(day until day+86400 step 5).map { GravitySample("device",it,0.0,0.0,0.0, dynAccel=0.0) }
        val dynOut=SleepOpportunityDetector.detect(day,day+86400,low,dynStill)
        assertEquals(listOf(nap to nap+1200),dynOut.episodes.map { it.start to it.end })
    }
    @Test fun enginePublishesTheAfternoonNapSeparatelyAndCausalModeNeverUsesRetrospectiveDetector() {
        val ranges=listOf(day+3600 until day+5*3600,nap until nap+1200)
        val result=AnalyticsEngine.analyzeDay("2026-09-17",hr=hr(ranges),gravity=gravity(),profile=UserProfile(),
            useFullDaySleepOpportunities=true)
        assertEquals(listOf("main_sleep","nap"),result.sleepSessions.map { it.episodeType })
        assertEquals(nap,result.sleepSessions.last().start)
        val causal=AnalyticsEngine.analyzeDay("2026-09-17",hr=hr(ranges),gravity=gravity(),profile=UserProfile(),
            useFullDaySleepOpportunities=true,sleepComputationMode="causal",sleepObservedThrough=nap)
        assertTrue(causal.sleepSessions.isEmpty())
    }
    @Test fun napsOnlyDayDoesNotBecomeMainSleepOrNocturnalHrvContext() {
        val result=AnalyticsEngine.analyzeDay("2026-09-17",hr=hr(listOf(nap until nap+1200)),gravity=gravity(),
            profile=UserProfile(),useFullDaySleepOpportunities=true)
        assertEquals("nap",result.sleepSessions.single().episodeType)
        assertNull(result.hrvNightSummary)
        assertTrue(result.hrvMeasurements.none { it.context=="sleep" })
    }
    @Test fun groupedOpportunityPreservesAwakeOffBodyAndMissingInterruptionsWithoutAddingSleep() {
        val sleep=day+3600 until day+5*3600
        val gap=day+2*3600 until day+2*3600+1800
        for(kind in listOf("reading","off_body","missing")) {
            val context=if(kind=="missing") emptyList() else listOf(SleepContextSpan(gap.first,gap.last+1,kind,"independent_annotation"))
            val motion=gravity().filter { kind!="missing" || it.ts !in gap }
            val result=AnalyticsEngine.analyzeDay("2026-09-17",hr=hr(listOf(sleep)),gravity=motion,profile=UserProfile(),
                sleepContext=context,useFullDaySleepOpportunities=true)
            val main=result.sleepSessions.filter { it.episodeType=="main_sleep" }
            assertEquals(2,main.size)
            assertEquals(main.last().start,main.first().end)
            val epochs=main.flatMap { it.stages }
            val interrupted=epochs.filter { it.start>=gap.first && it.end<=gap.last+1 }
            assertEquals(1800L,interrupted.sumOf { it.end-it.start })
            assertTrue(interrupted.all { it.state==when(kind) { "reading"->"awake";"off_body"->"off_body";else->"state_unknown" } })
            assertEquals(12600L,epochs.filter(SleepStageSemantics::isSleep).sumOf { it.end-it.start })
            assertTrue(result.hrvMeasurements.filter { it.start>=gap.first && it.end<=gap.last+1 }.none { it.context=="sleep" })
        }
    }

    @Test fun sharedFullDayGroupingOracleQualifiesBeforeRanking() {
        val fixtures=JSONArray(javaClass.getResource("/sleep_group_selection_oracle.json")!!.readText())
        for(index in 0 until fixtures.length()) {
            val fixture=fixtures.getJSONObject(index)
            val ranges=fixture.getJSONArray("sleep_ranges").let { rows -> (0 until rows.length()).map {
                val row=rows.getJSONArray(it); day+row.getLong(0) until day+row.getLong(1)
            } }
            val expected=fixture.getJSONArray("main_indices").let { rows -> (0 until rows.length()).map(rows::getInt) }
            for(v2 in listOf(false,true)) {
                val result=AnalyticsEngine.analyzeDay("2026-09-17",hr=hr(ranges),gravity=gravity(),profile=UserProfile(),
                    useFullDaySleepOpportunities=true,useSleepStagerV2=v2)
                assertEquals(fixture.getString("name"),ranges.size,result.sleepSessions.size)
                assertEquals(fixture.getString("name"),expected,result.sleepSessions.indices.filter {
                    result.sleepSessions[it].episodeType=="main_sleep"
                })
                if(expected.isEmpty()) assertNull(result.daily.totalSleepMin)
                else assertEquals(expected.sumOf { ranges[it].last+1-ranges[it].first }/60.0,
                    result.daily.totalSleepMin!!,0.0)
            }
        }
    }

    @Test fun mainGroupQualificationCountsSleepRatherThanEditedOpportunityDuration() {
        val longUncertain=DetectedSleep(day+3600,day+5*3600,0.0,listOf(
            StageSegment(day+3600,day+2*3600,"light"),
            SleepStageSemantics.unknown(day+2*3600,day+5*3600)),null,null)
        val shift=DetectedSleep(day+13*3600,day+15*3600,1.0,
            listOf(StageSegment(day+13*3600,day+15*3600,"light")),null,null)
        assertEquals(listOf(1),SleepOpportunityDetector.mainSleepGroupIndices(listOf(longUncertain,shift),0))
    }
}
