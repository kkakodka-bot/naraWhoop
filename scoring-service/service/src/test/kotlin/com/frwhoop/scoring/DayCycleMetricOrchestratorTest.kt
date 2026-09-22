package com.frwhoop.scoring

import com.frwhoop.scoring.db.*
import com.frwhoop.scoring.scoring.*
import com.noop.analytics.*
import com.noop.data.DailyMetric
import com.noop.data.HrSample
import com.noop.data.StepSample
import com.noop.protocol.DeviceFamily
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

class DayCycleMetricOrchestratorTest {
    private val owner=UUID.fromString("10000000-0000-4000-8000-000000000001")
    private val source="20000000-0000-4000-8000-000000000001"
    private fun input(day:String="2026-09-18",zone:String="UTC",config:JSONObject=JSONObject()):SignalSampleReader.DayInputs {
        val b=UserDayBounds.forDay(day,ZoneId.of(zone))
        return SignalSampleReader.DayInputs(owner,day,source,b.tzOffsetSeconds,b.dayLo,b.dayHi,UserProfile(),
            b.nightLo,b.nightHi,emptyList(),emptyList(),emptyList(),emptyList(),emptyList(),DeviceFamily.WHOOP5,zone,
            HistoryInputReader.Day(listOf(HistoryInputReader.Input("config","primary",1,false,config))))
    }
    private fun night(start:Long,end:Long)=DetectedSleep(start,end,1.0,listOf(StageSegment(start,end,"light")),60,null)
    private fun result(i:SignalSampleReader.DayInputs,sleeps:List<DetectedSleep>)=DayResult(
        DailyMetric(source,i.day,restingHr=60,strain=7.0,steps=999,activeKcalEst=888.0),sleeps,emptyList(),null,7.0)
    private fun prepared(i:SignalSampleReader.DayInputs,previous:JSONObject?=null)=HistoricalStateMachine.prepare(i,
        HistoryCheckpointReader.Seed(previous,listOfNotNull(previous?.getJSONObject("observation"))))

    @Test fun cycleUsesOneWindowExistingFormulasAndIgnoresFutureSignalsAndFutureNight() {
        val base=input();val s=night(base.dayLo-7200,base.dayLo+7*3600)
        val hr=(0 until 1000).map { HrSample(source,s.start+it*60,100+it%10) }.filter { it.ts<=base.dayHi }
        val i=base.copy(hr=hr);val r=result(i,listOf(s));val p=prepared(i)
        val out=DayCycleMetricOrchestrator.evaluate(i,r,p)
        assertEquals(s.start,out.window.startInclusive)
        assertEquals(base.dayHi+1,out.window.endExclusive)
        assertFalse(out.usesCalendar)
        assertEquals(StrainScorer.strain(hr,StrainScorer.tanakaHRmax(i.profile.age),60.0,StrainScorer.Method.EDWARDS,i.profile.sex),out.scored.strain)
        assertEquals(Calories.estimateDayCalories(hr,i.profile,StrainScorer.tanakaHRmax(i.profile.age),60.0),out.scored.daily.activeKcalEst!!,0.0)
        val future=i.copy(hr=hr+HrSample(source,i.dayHi+1,240))
        val again=DayCycleMetricOrchestrator.evaluate(future,r.copy(sleepSessions=listOf(s,night(i.dayHi-1000,i.dayHi+9*3600))),p)
        assertEquals(out.scored.daily,again.scored.daily)
        assertEquals(out.window,again.window)
        assertTrue(out.details(i.day).getBoolean("openAsOfCutoff"))
    }

    @Test fun sleepCounterIncludesPredecessorRejectsBedTwitchAndCountsCoherentBout() {
        val base=input();val start=base.dayLo;val end=start+7*3600
        val s=night(start,end).copy(stages=listOf(StageSegment(start,start+10,"wake"),StageSegment(start+10,end,"light")))
        val times=listOf(-1L,0,1,60,100,101,102,103,104)
        val rows=times.mapIndexed { index,t -> StepSample(source,start+t,index*2,1) }
        val i=base.copy(steps=rows)
        val out=DayCycleMetricOrchestrator.evaluate(i,result(i,listOf(s)),prepared(i))
        assertEquals(14,out.scored.daily.steps)
        assertEquals(4,out.stepCount!!.acceptedAwakeGapTicks)
        assertEquals(10,out.stepCount!!.acceptedSleepBoutTicks)
        assertEquals(2,out.stepCount!!.rejectedIsolatedSleepTicks)
        val empty=DayCycleMetricOrchestrator.evaluate(base,result(base,listOf(s)),prepared(base))
        assertNull(empty.scored.daily.steps)
        val stationary=base.copy(steps=listOf(StepSample(source,start,10,1),StepSample(source,start+1,10,1)))
        assertEquals(0,DayCycleMetricOrchestrator.evaluate(stationary,result(stationary,listOf(s)),prepared(stationary)).scored.daily.steps)
    }

    @Test fun midnightColdStartAndExplicitNapDoNotAccidentallyCreateMainCycle() {
        val i=input();val s=night(i.dayLo,i.dayLo+7*3600);val r=result(i,listOf(s))
        val nap=DayCycleMetricOrchestrator.evaluate(i,r,prepared(i),naps=mapOf(SleepBounds(s.start,s.end) to true))
        assertTrue(nap.usesCalendar);assertEquals(r,nap.scored)
        val cold=DayCycleMetricOrchestrator.evaluate(i,result(i,emptyList()),prepared(i))
        assertTrue(cold.usesCalendar)
        val midnight=input(config=JSONObject().put("dayCycleMode","midnight"))
        assertEquals(r,DayCycleMetricOrchestrator.evaluate(midnight,r,prepared(midnight)).scored)
    }

    @Test fun immutableCycleIdentitySurvivesEditedBoundsAndCheckpointRestart() {
        val i=input();val s=night(i.dayLo-3600,i.dayLo+7*3600)
        val id=SleepIdentity.detected(owner,source,s.start,s.end)
        val moved=s.copy(start=s.start+1800)
        val r=result(i,listOf(moved));val p=prepared(i)
        val cycle=DayCycleMetricOrchestrator.evaluate(i,r,p,mapOf(SleepBounds(moved.start,moved.end) to id))
        assertEquals(id.id,cycle.window.id)
        assertEquals(moved.start,cycle.window.startInclusive)
        val checkpoint=HistoricalStateMachine.finish(i,cycle.scored,p,emptyMap()).state
        checkpoint.getJSONObject("observation").put("dayCycle",cycle.details(i.day))
        val next=input("2026-09-19")
        val again=DayCycleMetricOrchestrator.evaluate(next,result(next,emptyList()),prepared(next,JSONObject(checkpoint.toString())))
        assertEquals(DayCycleWindow.Source.SYNTHETIC_MIDNIGHT,again.window.source)
        assertEquals(next.dayLo,again.window.startInclusive)
        assertEquals("2026-09-18",checkpoint.getString("throughDay"))
    }

    @Test fun actualZoneWindowsCoverShortLongFractionalAndMiddayTransitionDays() {
        for((date,name) in listOf("2026-03-08" to "America/Los_Angeles","2026-11-01" to "America/Los_Angeles",
            "2026-10-04" to "Australia/Lord_Howe","2026-04-05" to "Australia/Lord_Howe",
            "2000-01-15" to "Africa/Khartoum","2026-09-18" to "Asia/Kathmandu")) {
            val i=input(date,name);val zone=ZoneId.of(name);val d=LocalDate.parse(date)
            val start=d.minusDays(1).atTime(22,0).atZone(zone).toEpochSecond()
            val sleep=night(start,d.atTime(7,0).atZone(zone).toEpochSecond())
            val out=DayCycleMetricOrchestrator.evaluate(i,result(i,listOf(sleep)),prepared(i))
            assertEquals("$date $name",start,out.window.startInclusive)
            assertEquals(d.plusDays(1).atStartOfDay(zone).toEpochSecond(),out.window.endExclusive)
            assertEquals(i.dayLo,DayCycleResolver.calendarWindow(i.dayHi,0,zone).startInclusive)
            val minimum=start+DayCycleResolver.MIN_SYNTHETIC_MIDNIGHT_AGE_SECONDS
            val expected=Instant.ofEpochSecond(minimum).atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone).toEpochSecond()
            assertEquals(expected,DayCycleResolver.fallbackMidnightAfter(start,0,zone))
        }
    }

    @Test fun calendarImportsRemainSeparateFromSleepCycleTotals() {
        val base=input();val sleep=night(base.dayLo-3600,base.dayLo+7*3600)
        val imported=HistoryInputReader.Input("imported_daily","import:test",1,false,JSONObject().put("day",base.day)
            .put("source",JSONObject().put("kind","apple_health").put("externalDeviceId","phone").put("method","daily_total"))
            .put("values",JSONObject().put("active_energy_kcal",JSONObject().put("value",999).put("unit","kcal"))
                .put("steps_count",JSONObject().put("value",999).put("unit","count"))))
        val i=base.copy(history=HistoryInputReader.Day(base.history.values+imported))
        val p=prepared(i);val cycle=DayCycleMetricOrchestrator.evaluate(i,result(i,listOf(sleep)),p)
        val commit=HistoricalStateMachine.finish(i,cycle.scored,p,emptyMap())
        val output=ServerMetricOrchestrator.evaluate(i,cycle.scored,commit,cycle=cycle)
        assertTrue(output.metrics.getJSONObject("active_kcal_est").isNull("value"))
        assertTrue(output.metrics.getJSONObject("steps").isNull("value"))
        assertEquals(999,output.metrics.getJSONObject("imported_calendar_active_energy_kcal").getInt("value"))
        assertEquals(999,output.metrics.getJSONObject("imported_calendar_steps_count").getInt("value"))
    }
}
