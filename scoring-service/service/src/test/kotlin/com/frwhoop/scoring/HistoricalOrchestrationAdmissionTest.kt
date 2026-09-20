package com.frwhoop.scoring

import com.frwhoop.scoring.db.*
import com.frwhoop.scoring.scoring.*
import com.noop.analytics.*
import com.noop.data.DailyMetric
import com.noop.data.HrSample
import com.noop.data.RrInterval
import com.noop.protocol.DeviceFamily
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.UUID
import kotlin.math.exp
import kotlin.math.ln

/** Checkpoint inputs are synthetic; prepare/finish, DayScorer and metric engines are production code. */
class HistoricalOrchestrationAdmissionTest {
    private val owner=UUID.fromString("10000000-0000-4000-8000-000000000001")
    private val device="20000000-0000-4000-8000-000000000001"
    private fun date(n:Int)=LocalDate.parse("2026-01-01").plusDays(n.toLong()).toString()
    private fun epoch(day:String)=LocalDate.parse(day).atStartOfDay(ZoneOffset.UTC).toEpochSecond().toDouble()
    private fun input(day:String,config:JSONObject=JSONObject()):SignalSampleReader.DayInputs {
        val b=UserDayBounds.forDay(day,ZoneOffset.UTC)
        val profile=HistoryInputReader.Input("profile","primary",1,false,JSONObject().put("schemaVersion",1)
            .put("age",40).put("sex","female").put("timezone","UTC").put("heightCm",170).put("weightKg",60))
        return SignalSampleReader.DayInputs(owner,day,device,0,b.dayLo,b.dayHi,UserProfile(age=40.0,sex="female"),
            b.nightLo,b.nightHi,emptyList(),emptyList(),emptyList(),emptyList(),emptyList(),DeviceFamily.WHOOP5,
            history=HistoryInputReader.Day(listOf(profile,HistoryInputReader.Input("config","primary",2,false,config))))
    }
    private fun result(i:SignalSampleReader.DayInputs,n:Int):DayResult {
        val temp=33.0+if(n%28>=14) .3 else -.3
        val d=DailyMetric(device,i.day,totalSleepMin=420.0,efficiency=1.0,restingHr=55+n%3,avgHrv=50.0+n%3,
            skinTempC=temp,strain=30.0+n%4,respRateBpm=15.0+n%3*.1,steps=9000)
        val sleep=DetectedSleep(i.dayLo-3600,i.dayLo+6*3600,1.0,
            listOf(StageSegment(i.dayLo-3600,i.dayLo+6*3600,"light")),d.restingHr,d.avgHrv)
        return DayResult(d,listOf(sleep),emptyList(),null,d.strain,nightlySkinTempC=temp)
    }
    private fun seed(states:List<HistoricalStateMachine.Commit>,reopen:Boolean=true)=HistoryCheckpointReader.Seed(
        states.lastOrNull()?.state?.let { if(reopen) JSONObject(it.toString()) else it },
        states.map { JSONObject(it.state.getJSONObject("observation").toString()) })
    private fun warm(count:Int,skip:Set<Int> = emptySet(),config:JSONObject=JSONObject()):List<HistoricalStateMachine.Commit> {
        val states=mutableListOf<HistoricalStateMachine.Commit>()
        repeat(count) { n -> if(n !in skip) {
            val i=input(date(n),config);val p=HistoricalStateMachine.prepare(i,seed(states))
            states+=HistoricalStateMachine.finish(i,result(i,n),p,emptyMap())
        } }
        return states
    }
    private fun derive(i:SignalSampleReader.DayInputs,r:DayResult,states:List<HistoricalStateMachine.Commit>):ServerDerivedMetrics {
        val p=HistoricalStateMachine.prepare(i,seed(states))
        return ServerMetricOrchestrator.evaluate(i,r,HistoricalStateMachine.finish(i,r,p,emptyMap()))
    }
    private fun measured(i:SignalSampleReader.DayInputs):SignalSampleReader.DayInputs {
        val lo=i.dayLo-3600;val hi=i.dayLo+6*3600
        val edit=HistoryInputReader.Input("sleep_edit","sleep:40000000-0000-4000-8000-000000000010",3,false,
            JSONObject().put("schemaVersion",1).put("originalStart",lo).put("originalEnd",hi).put("start",lo).put("end",hi)
                .put("isNap",false).put("dismissed",false).put("stages",JSONArray().put(JSONObject().put("start",lo).put("end",hi).put("stage","light"))))
        return i.copy(hr=List(840) { HrSample(device,lo+it*30,60+it%2) },
            rr=List(3000) { RrInterval(device,lo+it,1000+it%5*12) },history=HistoryInputReader.Day(i.history.values+edit))
    }
    private fun signals(d:ServerDerivedMetrics):List<JSONObject> = d.details.getJSONObject("readiness").getJSONArray("signals").let {
        (0 until it.length()).map(it::getJSONObject)
    }
    private fun assertNullMetric(d:ServerDerivedMetrics,key:String)=assertTrue("$key: ${d.metrics.get(key)}",d.metrics.getJSONObject(key).isNull("value"))
    private fun context(i:SignalSampleReader.DayInputs,r:DayResult,states:List<HistoricalStateMachine.Commit>):HistoricalContextResult {
        val p=HistoricalStateMachine.prepare(i,seed(states))
        return ContextMetricOrchestrator.evaluate(HistoricalContextInputFactory.build(i,r,p))
    }

    @Test fun actualDayScorerCannotResurrectStaleOrFullyResetReadinessAndStress() {
        val states=warm(45)
        val reset=JSONObject().put("hrvBaselineEpoch",epoch(date(45))).put("recoveryBaselineEpoch",epoch(date(45)))
        for(base in listOf(input("2026-09-18"),input(date(45),reset))) {
            val i=measured(base);val p=HistoricalStateMachine.prepare(i,seed(states))
            assertFalse(p.baselines.getValue("hrv").usable);assertFalse(p.baselines.getValue("resting_hr").usable)
            val scored=DayScorer().score(i,"frwhoop-server-2-history",p)
            assertNotNull(scored.result.daily.restingHr)
            val d=scored.derived!!
            assertTrue(signals(d).isEmpty())
            assertEquals("insufficient",d.details.getJSONObject("readiness").getString("level"))
            assertEquals("calibrating",d.details.getJSONObject("readiness").getString("confidence"))
            for(key in listOf("stress","acwr","fitness_age")) assertNullMetric(d,key)
        }
    }

    @Test fun partialResetsKeepOnlyIndependentEligiblePhysiology() {
        val states=warm(45)
        for(reset in listOf("hrvBaselineEpoch","recoveryBaselineEpoch")) {
            val i=input(date(45),JSONObject().put(reset,epoch(date(45))))
            val d=derive(i,result(i,45),states);val keys=signals(d).map { it.getString("key") }.toSet()
            if(reset=="hrvBaselineEpoch") { assertFalse("hrv" in keys);assertTrue("rhr" in keys) }
            else { assertTrue("hrv" in keys);assertFalse("rhr" in keys);assertFalse("respRate" in keys);assertNullMetric(d,"acwr") }
            assertFalse("one still-eligible signal may produce daily stress",d.metrics.getJSONObject("stress").isNull("value"))
        }
    }

    @Test fun missingCurrentDayNeverPublishesOldWeeklyOrReadinessOutputs() {
        val i=input(date(45));val p=HistoricalStateMachine.prepare(i,seed(warm(45)))
        val scored=DayScorer().score(i,"frwhoop-server-2-history",p)
        assertEquals("no_data",EngineIngestWriter.buildSnapshot(scored).getString("status"))
        assertTrue(signals(scored.derived!!).isEmpty())
        for(key in listOf("fitness_age","vo2max_est","vitality","body_age","stress","acwr")) assertNullMetric(scored.derived!!,key)
    }

    @Test fun recentCalendarGapCannotBorrowOldStrainAndPhysiologyFoldKeepsMissingSlots() {
        val states=warm(45,skip=setOf(43));val i=input(date(45));val r=result(i,45)
        val d=derive(i,r,states)
        assertNullMetric(d,"acwr");assertNullMetric(d,"training_monotony")
        val byDay=states.associateBy { it.prepared.day }
        val base=(15 until 45).map { n -> byDay[date(n)]?.state?.getJSONObject("observation")?.getJSONObject("daily")?.getDouble("avgHrv")?.let(::ln) }
        val expected=Baselines.foldHistory(base,Baselines.readinessHRVLnCfg,rejectHardOutliers=false)
        val evidence=signals(d).single { it.getString("key")=="hrv" }.getJSONObject("evidence")
        assertEquals(exp(expected.baseline),evidence.getDouble("baseline"),1e-12)
    }

    @Test fun gapInsideChronicWindowRestartsItsObservedSuffixInsteadOfCompressingDays() {
        val states=warm(45,skip=setOf(25));val i=input(date(45));val d=derive(i,result(i,45),states)
        val acute=(39..45).map { 30.0+it%4 }.average()
        val chronic=(26..45).map { 30.0+it%4 }.average()
        assertEquals(acute/chronic,d.metrics.getJSONObject("acwr").getDouble("value"),1e-12)
        assertEquals(20,d.details.getJSONObject("training_load").getInt("contiguousDays"))
    }

    @Test fun sourceEraAndEffortRecipeSwitchDoNotBorrowOldLoad() {
        val states=warm(45)
        for(config in listOf(JSONObject().put("sourceEra","replacement"),JSONObject().put("effortMethod","BANISTER"))) {
            val i=input(date(45),config);val d=derive(i,result(i,45),states)
            assertNullMetric(d,"acwr");assertNullMetric(d,"chronic_load")
            if(config.has("sourceEra")) { assertNullMetric(d,"stress");assertNullMetric(d,"fitness_age") }
            else {
                // Recipe changes invalidate load, not independent RHR. The existing optional-activity
                // model still computes an estimate, using only today's single eligible activity day.
                val expected=requireNotNull(FitnessAgeEngine.compute(40.0,"female",56.0,
                    FitnessAgeEngine.physicalActivityIndexFromStrain(1,31.0),null))
                assertEquals(expected.fitnessAge,d.metrics.getJSONObject("fitness_age").getDouble("value"),1e-12)
                assertEquals("estimate",d.details.getJSONObject("fitness_age").getString("confidence"))
            }
        }
    }

    @Test fun fractionalUtcResetDoesNotAdmitItsPartiallyElapsedDay() {
        val states=warm(45)
        for(zone in listOf("UTC","Pacific/Kiritimati","America/Los_Angeles")) {
            val i=input(date(45),JSONObject().put("hrvBaselineEpoch",epoch(date(45))+.25)
                .put("recoveryBaselineEpoch",epoch(date(45))+.25)).copy(timezone=zone)
            val d=derive(i,result(i,45),states)
            assertTrue(signals(d).isEmpty());assertNullMetric(d,"stress");assertNullMetric(d,"fitness_age");assertNullMetric(d,"vitality")
        }
    }

    @Test fun contiguousReadinessNumericsAndConfidenceRemainTheExistingEngine() {
        val states=warm(45);val i=input(date(45));val r=result(i,45);val d=derive(i,r,states)
        val expected=ReadinessEngine.evaluate(states.map { DailyMetricJson.decode(it.state.getJSONObject("observation").getJSONObject("daily")) }+r.daily,i.day)
        val actual=d.details.getJSONObject("readiness")
        assertEquals(expected.level.name.lowercase(),actual.getString("level"));assertEquals(expected.confidence.name.lowercase(),actual.getString("confidence"))
        assertEquals(expected.acwr!!,d.metrics.getJSONObject("acwr").getDouble("value"),1e-12)
        assertEquals(expected.signals.map { it.key },signals(d).map { it.getString("key") })
        for(signal in expected.signals) if(signal.evidence is ReadinessEngine.Evidence.MetricVsBaseline) {
            val e=signal.evidence as ReadinessEngine.Evidence.MetricVsBaseline
            assertEquals(e.baseline,signals(d).single { it.getString("key")==signal.key }.getJSONObject("evidence").getDouble("baseline"),1e-12)
        }
    }

    @Test fun actualNoDataCycleDayCannotBecomeAConfidentFollicularTransition() {
        val states=warm(74);val config=JSONObject().put("cycleAwarenessEnabled",true)
        val prior=input(date(73),config)
        assertEquals("luteal",context(prior,result(prior,73),states.dropLast(1)).details.getJSONObject("cycle").getString("phase"))
        val i=input(date(74),config);val p=HistoricalStateMachine.prepare(i,seed(states))
        val scored=DayScorer().score(i,"frwhoop-server-2-history",p)
        assertEquals("no_data",EngineIngestWriter.buildSnapshot(scored).getString("status"))
        val cycle=scored.derived!!.details.getJSONObject("cycle")
        assertEquals("learning",cycle.getString("phase"));assertEquals("learning",cycle.getString("confidence"))
        assertTrue(scored.coverageGaps.contains("cycle_current_physiology_unavailable"))
        assertTrue(cycle.isNull("cycleLengthDays"));assertEquals(0,cycle.getJSONArray("shiftMarkers").length())
    }

    @Test fun missingTemperatureCanUseDeclaredCurrentCorroborationButNotAnEmptyCurrentSlot() {
        val states=warm(74);val i=input(date(74),JSONObject().put("cycleAwarenessEnabled",true));val r=result(i,74)
        val partial=r.copy(daily=r.daily.copy(skinTempC=null),nightlySkinTempC=null)
        val supported=context(i,partial,states)
        assertNotEquals("learning",supported.details.getJSONObject("cycle").getString("phase"))
        assertTrue(supported.gaps.contains("cycle_current_temperature_unavailable"))
        val empty=context(i,partial.copy(daily=DailyMetric(device,i.day)),states)
        assertEquals("learning",empty.details.getJSONObject("cycle").getString("phase"))
    }

    @Test fun unknownCalendarSlotDoesNotCreateANewObservedCycleOnset() {
        val states=warm(74,skip=setOf(72));val i=input(date(73),JSONObject().put("cycleAwarenessEnabled",true))
        val result=context(i,result(i,73),states.filter { it.prepared.day<i.day })
        assertFalse(result.details.getJSONObject("cycle").getJSONArray("shiftMarkers").toList().contains(i.day))
        assertEquals("luteal",result.details.getJSONObject("cycle").getString("phase"))
    }

    @Test fun fullCycleResetRetainsHistoricalChartsButCannotReuseTheirFeaturesAfterFourteenNights() {
        val states=warm(74).toMutableList();val reset=epoch(date(74))
        val config=JSONObject().put("cycleAwarenessEnabled",true).put("hrvBaselineEpoch",reset).put("recoveryBaselineEpoch",reset)
        repeat(14) { offset -> val i=input(date(74+offset),config);val p=HistoricalStateMachine.prepare(i,seed(states))
            states+=HistoricalStateMachine.finish(i,result(i,74+offset),p,emptyMap()) }
        val i=input(date(88),config);val p=HistoricalStateMachine.prepare(i,seed(states))
        assertEquals(14,p.baselines.getValue("skin_temp").nValid)
        val result=context(i,result(i,88),states);val cycle=result.details.getJSONObject("cycle")
        assertEquals("learning",cycle.getString("phase"));assertEquals(0,cycle.getJSONArray("shiftMarkers").length())
        assertTrue(cycle.isNull("cycleLengthDays"))
        val chart=result.charts.getJSONArray("cycle_index")
        assertTrue("immutable historical chart remains",(0 until chart.length()).any { chart.getJSONObject(it).getLong("start")<reset })
    }

    @Test fun actualObservedDecreaseStillClassifiesAndSourceEraDoesNotReuseOldCycle() {
        val states=warm(74);val config=JSONObject().put("cycleAwarenessEnabled",true)
        val i=input(date(74),config);val r=result(i,74)
        val decreased=r.copy(daily=r.daily.copy(skinTempC=32.0,restingHr=50,avgHrv=75.0),nightlySkinTempC=32.0)
        assertEquals("follicular",context(i,decreased,states).details.getJSONObject("cycle").getString("phase"))
        val replacement=input(date(74),JSONObject(config.toString()).put("sourceEra","replacement"))
        val changed=context(replacement,result(replacement,74),states)
        assertEquals("learning",changed.details.getJSONObject("cycle").getString("phase"))
        assertEquals(0,changed.charts.getJSONArray("cycle_index").length())
    }

    private fun eligibleCycleInput():HistoricalContextInputs {
        val before=mapOf("skin_temp" to BaselineState(33.0,.1,60,0,BaselineStatus.TRUSTED),
            "resting_hr" to BaselineState(55.0,2.0,60,0,BaselineStatus.TRUSTED),
            "hrv" to BaselineState(50.0,5.0,60,0,BaselineStatus.TRUSTED))
        val rows=(0..71).map { n ->
            val i=input(date(n));HistoricalDailyObservation(i.day,result(i,n).daily,before)
        }
        return HistoricalContextInputs(date(71),"UTC",rows,before,emptyList(),emptyList(),emptyList(),
            emptyList(),emptyList(),false,true,emptyMap(),emptyList(),baselineEpochSeconds=before.keys.associateWith { 0.0 })
    }

    @Test fun cycleCountsExactlyFortyTwoEligibleFeaturesAndUsesFractionalUtcBoundaryInAllZones() {
        val base=eligibleCycleInput()
        for(zone in listOf("UTC","Pacific/Kiritimati","America/Los_Angeles")) {
            val exact=base.copy(timezone=zone,baselineEpochSeconds=base.baselinesBefore.keys.associateWith { epoch(date(30)) })
            val accepted=ContextMetricOrchestrator.evaluate(exact)
            assertNotEquals("learning",accepted.details.getJSONObject("cycle").getString("phase"))
            assertTrue(accepted.details.getJSONObject("cycle").getJSONArray("shiftMarkers").toList().all { it.toString()>=date(30) })
            val partial=exact.copy(baselineEpochSeconds=exact.baselineEpochSeconds.mapValues { it.value+.25 })
            val learning=ContextMetricOrchestrator.evaluate(partial)
            assertEquals("learning",learning.details.getJSONObject("cycle").getString("phase"))
            assertEquals(0,learning.details.getJSONObject("cycle").getJSONArray("shiftMarkers").length())
            assertTrue(accepted.charts.similar(learning.charts))
        }
    }

    @Test fun cyclePartialResetMasksOnlyItsOwnFeaturesAndKeepsImmutableCharts() {
        val base=eligibleCycleInput()
        for(resetKeys in listOf(setOf("hrv"),setOf("resting_hr","skin_temp"))) {
            val input=base.copy(baselineEpochSeconds=base.baselineEpochSeconds+resetKeys.associateWith { epoch(date(30)) })
            // Independent control removes only ineligible measurements before calling the same
            // adapter with no reset, leaving the eligible nightly before-states exactly unchanged.
            val filtered=base.copy(history=base.history.map { row ->
                if(row.day>=date(30)) row else row.copy(daily=row.daily.copy(
                    avgHrv=row.daily.avgHrv.takeUnless { "hrv" in resetKeys },
                    restingHr=row.daily.restingHr.takeUnless { "resting_hr" in resetKeys },
                    skinTempC=row.daily.skinTempC.takeUnless { "skin_temp" in resetKeys }))
            })
            val actual=ContextMetricOrchestrator.evaluate(input)
            val expected=ContextMetricOrchestrator.evaluate(filtered)
            assertTrue(actual.details.getJSONObject("cycle").similar(expected.details.getJSONObject("cycle")))
            assertNotEquals("learning",actual.details.getJSONObject("cycle").getString("phase"))
            assertTrue(actual.charts.similar(ContextMetricOrchestrator.evaluate(base).charts))
        }
        val unknown=ContextMetricOrchestrator.evaluate(base.copy(baselineEpochSeconds=emptyMap()))
        assertEquals("learning",unknown.details.getJSONObject("cycle").getString("phase"))
        assertTrue(unknown.gaps.contains("cycle_reset_policy_unavailable"))
    }

    @Test fun checkpointJsonReopenAndFreshReplayHaveIdenticalResetAdmission() {
        val states=warm(74).toMutableList()
        val config=JSONObject().put("cycleAwarenessEnabled",true).put("hrvBaselineEpoch",epoch(date(74)))
            .put("recoveryBaselineEpoch",epoch(date(74)))
        repeat(55) { offset -> val i=input(date(74+offset),config);val p=HistoricalStateMachine.prepare(i,seed(states))
            states+=HistoricalStateMachine.finish(i,result(i,74+offset),p,emptyMap()) }
        val i=input(date(129),config);val persisted=seed(states)
        val resumed=HistoricalStateMachine.prepare(i,persisted)
        val replay=HistoricalStateMachine.prepare(i,HistoryCheckpointReader.Seed(null,persisted.history))
        assertEquals(resumed.baselines,replay.baselines)
        val outputs=listOf(resumed,replay).map { p -> ContextMetricOrchestrator.evaluate(HistoricalContextInputFactory.build(i,result(i,129),p)) }
        assertTrue(outputs[0].details.similar(outputs[1].details));assertTrue(outputs[0].charts.similar(outputs[1].charts))
        assertNotEquals("learning",outputs[0].details.getJSONObject("cycle").getString("phase"))
        assertTrue(outputs[0].details.getJSONObject("cycle").getJSONArray("shiftMarkers").toList().all { it.toString()>=date(74) })
        val derived=listOf(resumed,replay).map { p ->
            val r=result(i,129)
            ServerMetricOrchestrator.evaluate(i,r,HistoricalStateMachine.finish(i,r,p,emptyMap()))
        }
        assertTrue(derived[0].metrics.similar(derived[1].metrics))
        assertTrue(derived[0].details.similar(derived[1].details))
        assertTrue(derived[0].charts.similar(derived[1].charts))
    }
}
