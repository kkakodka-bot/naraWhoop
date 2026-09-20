package com.frwhoop.scoring

import com.frwhoop.scoring.db.*
import com.frwhoop.scoring.scoring.*
import com.noop.analytics.*
import com.noop.data.DailyMetric
import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.V18AuxRow
import com.noop.protocol.DeviceFamily
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID

class ServerMetricOrchestratorTest {
    private val owner=UUID.fromString("10000000-0000-4000-8000-000000000001")
    private val source="20000000-0000-4000-8000-000000000001"
    private fun input(day:String,extra:List<HistoryInputReader.Input> = emptyList()):SignalSampleReader.DayInputs {
        val bounds=UserDayBounds.forDay(day,ZoneId.of("UTC"))
        return SignalSampleReader.DayInputs(owner,day,source,0,bounds.dayLo,bounds.dayHi,UserProfile(age=40.0,sex="female"),
            bounds.nightLo,bounds.nightHi,List(12) { HrSample(source,bounds.dayLo+3600+it*30,80+it%2) },emptyList(),emptyList(),emptyList(),emptyList(),DeviceFamily.WHOOP5,
            history=HistoryInputReader.Day(listOf(HistoryInputReader.Input("profile","primary",1,false,JSONObject()
                .put("schemaVersion",1).put("age",40).put("sex","female").put("timezone","UTC").put("weightKg",60).put("heightCm",170)))+extra))
    }
    private fun result(input:SignalSampleReader.DayInputs,hrv:Double=50.0)=DayResult(
        DailyMetric(source,input.day,totalSleepMin=420.0,efficiency=.875,deepMin=80.0,remMin=100.0,lightMin=240.0,disturbances=2,
            restingHr=55,avgHrv=hrv,recovery=75.0,strain=40.0,exerciseCount=0,skinTempDevC=.1,respRateBpm=15.0,steps=9000,
            activeKcalEst=750.0,spo2Red=800,spo2Ir=900,avgSdnn=60.0,skinTempC=33.0,sleepHrOnly=false),
        listOf(DetectedSleep(input.dayLo,input.dayLo+8*3600,.875,listOf(StageSegment(input.dayLo,input.dayLo+7*3600,"light")),55,hrv)),
        emptyList(),75.0,40.0,85.0,33.0)
    private fun evaluate(input:SignalSampleReader.DayInputs,result:DayResult,seed:HistoryCheckpointReader.Seed=HistoryCheckpointReader.Seed(null,emptyList())):Pair<HistoricalStateMachine.Commit,ServerDerivedMetrics> {
        val prepared=HistoricalStateMachine.prepare(input,seed)
        val commit=HistoricalStateMachine.finish(input,result,prepared,emptyMap())
        return commit to ServerMetricOrchestrator.evaluate(input,result,commit)
    }

    @Test fun completeDailyAndModelOutputsUseExistingNamesUnitsAndExplicitCapabilities() {
        val input=input("2026-09-18"); val result=result(input); val (commit,derived)=evaluate(input,result)
        val bundle=ServerScoreBundle(owner,input.day,source,"frwhoop-server-2-history",result,dataThrough=input.dayLo+7200,
            historyCommit=commit,derived=derived)
        val snapshot=EngineIngestWriter.buildSnapshot(bundle)
        for(key in listOf("recovery","strain","steps","active_kcal_est","spo2_red","spo2_ir","skin_temp_c","skin_temp_dev_c")) {
            assertTrue(key,snapshot.getJSONObject("daily").has(key))
            assertTrue(key,snapshot.getJSONArray("capabilities").toList().contains(key))
        }
        assertEquals(87.5,derived.metrics.getJSONObject("sleep_efficiency").getDouble("value"),0.0)
        assertEquals("percent",derived.metrics.getJSONObject("sleep_efficiency").getString("unit"))
        assertTrue(derived.metrics.getJSONObject("fitness_age").isNull("value"))
        assertEquals("not_ready",derived.details.getJSONObject("fitness_age").getString("confidence"))
        assertEquals(85.0,derived.metrics.getJSONObject("sleep_performance").getDouble("value"),0.0)
        assertEquals("descriptive_mean_need_floor_450",derived.metrics.getJSONObject("hours_vs_needed_pct").getString("method"))
    }

    @Test fun orderedHistoryUsesEachDaysOwnMetricsAndBoundedSnapshotBelowClientByteLimit() {
        val states=mutableListOf<HistoricalStateMachine.Commit>()
        var output:ServerDerivedMetrics?=null
        repeat(45) { i ->
            val input=input(LocalDate.parse("2026-01-01").plusDays(i.toLong()).toString())
            val (commit,derived)=evaluate(input,result(input,50.0+i%4),HistoryCheckpointReader.Seed(states.lastOrNull()?.state,
                states.map { it.state.getJSONObject("observation") }))
            states+=commit; output=derived
        }
        val d=output!!
        assertEquals(30,d.history.length())
        assertEquals("2026-02-13",d.history.getJSONObject(29).getString("day"))
        assertTrue(d.history.getJSONObject(29).getJSONObject("metrics").similar(states[43].state.getJSONObject("observation").getJSONObject("metrics")))
        assertEquals(40.0,d.metrics.getJSONObject("chronic_load").getDouble("value"),1e-12)
        assertEquals(0.0,d.metrics.getJSONObject("training_balance").getDouble("value"),1e-12)
        assertEquals("established",d.details.getJSONObject("training_load").getString("state"))
        assertFalse(d.metrics.getJSONObject("fitness_age").isNull("value"))
        assertFalse(d.metrics.getJSONObject("body_age").isNull("value"))
        val bundle=ServerScoreBundle(owner,"2026-02-14",source,"frwhoop-server-2-history",result(input("2026-02-14")),
            historyCommit=states.last(),derived=d,dataThrough=1)
        assertTrue(EngineIngestWriter.buildSnapshot(bundle).toString().toByteArray().size<512*1024)
    }

    @Test fun chartsOnlyContainObservedBucketsWithCountsAndBounds() {
        val input=input("2026-09-18"); val (_,d)=evaluate(input,result(input))
        val points=d.charts.getJSONArray("day_hr")
        assertEquals(2,points.length())
        assertEquals(10,points.getJSONObject(0).getInt("count"))
        assertEquals(2,points.getJSONObject(1).getInt("count"))
        assertEquals(80.5,points.getJSONObject(0).getDouble("value"),0.0)
        assertEquals(input.dayLo+3600,points.getJSONObject(0).getLong("start"))
        assertEquals(80.0,points.getJSONObject(0).getDouble("min"),0.0)
        assertEquals(81.0,points.getJSONObject(0).getDouble("max"),0.0)
    }

    @Test fun importedEnergyHasDeterministicProvenanceAndNeverReplacesStrapHrv() {
        fun imported(entity:String,kind:String,energy:Double)=HistoryInputReader.Input("imported_daily",entity,2,false,JSONObject()
            .put("day","2026-09-18").put("source",JSONObject().put("kind",kind).put("externalDeviceId","source").put("method","measured"))
            .put("values",JSONObject().put("active_energy_kcal",JSONObject().put("value",energy).put("unit","kcal"))
                .put("hrv_rmssd_ms",JSONObject().put("value",150).put("unit","ms"))))
        val a=imported("a","oura_import",900.0); val b=imported("b","apple_health",500.0)
        val input=input("2026-09-18",listOf(a,b)); val (_,d)=evaluate(input,result(input))
        assertEquals(500.0,d.metrics.getJSONObject("active_kcal_est").getDouble("value"),0.0)
        assertEquals(50.0,d.metrics.getJSONObject("hrv_rmssd_ms").getDouble("value"),0.0)
        assertEquals(150.0,d.metrics.getJSONObject("imported_hrv_rmssd_ms").getDouble("value"),0.0)
        assertEquals("apple_health",d.details.getJSONObject("imported_provenance").getJSONObject("imported_hrv_rmssd_ms").getJSONObject("source").getString("kind"))
        assertEquals("apple_health",d.details.getJSONObject("imported_provenance").getJSONObject("active_kcal_est").getJSONObject("source").getString("kind"))
        val reversed=input.copy(history=HistoryInputReader.Day(input.history.values.reversed()))
        assertTrue(d.metrics.similar(evaluate(reversed,result(reversed)).second.metrics))
    }

    @Test fun everyAcceptedImportedScalarHasAnExplicitOutputWithoutEnteringStrapBeforeStates() {
        val units=mapOf("steps_count" to "count","active_energy_kcal" to "kcal","basal_energy_kcal" to "kcal",
            "vo2max_ml_kg_min" to "mL/kg/min","body_mass_kg" to "kg","lean_mass_kg" to "kg","body_fat_pct" to "%",
            "spo2_pct" to "%","bmi_kg_m2" to "kg/m2","avg_hr_bpm" to "bpm","resting_hr_bpm" to "bpm",
            "hrv_rmssd_ms" to "ms","hrv_sdnn_ms" to "ms","resp_rate_bpm" to "breaths/min","skin_temp_c" to "degC",
            "sleep_total_min" to "min","sleep_debt_min" to "min","sleep_performance_pct" to "%",
            "sleep_consistency_pct" to "%","sleep_need_min" to "min")
        val import=HistoryInputReader.Input("imported_daily","import:all",2,false,JSONObject().put("day","2026-09-18")
            .put("source",JSONObject().put("kind","oura_import").put("externalDeviceId","ring").put("method","vendor_daily"))
            .put("values",JSONObject(units.mapValues { (_,unit) -> JSONObject().put("value",25).put("unit",unit) })))
        val i=input("2026-09-18",listOf(import));val (commit,d)=evaluate(i,result(i))
        val outputs=listOf("steps","active_kcal_est","basal_energy_kcal","vo2max_measured","body_mass_kg","lean_mass_kg",
            "body_fat_pct","spo2_pct","bmi_kg_m2","imported_avg_hr_bpm","imported_resting_hr_bpm","imported_hrv_rmssd_ms",
            "imported_hrv_sdnn_ms","imported_resp_rate_bpm","imported_skin_temp_c","imported_sleep_total_min","sleep_debt_min",
            "sleep_performance","sleep_consistency","sleep_need_min")
        for(key in outputs) {
            assertEquals(key,25.0,d.metrics.getJSONObject(key).getDouble("value"),0.0)
            assertTrue(key,d.capabilities.contains(key))
            assertEquals("oura_import",d.details.getJSONObject("imported_provenance").getJSONObject(key).getJSONObject("source").getString("kind"))
        }
        assertEquals(50.0,commit.state.getJSONObject("observation").getJSONObject("baselineObservations").getDouble("hrv"),0.0)
        assertEquals(55.0,d.metrics.getJSONObject("resting_hr_bpm").getDouble("value"),0.0)
        assertEquals(420.0,d.metrics.getJSONObject("sleep_total_min").getDouble("value"),0.0)
    }

    @Test fun importedSleepDisplayPrecedenceDoesNotChangeComputedRestOrDebtState() {
        fun imported(need:Any)=HistoryInputReader.Input("imported_daily","import:sleep",2,false,JSONObject().put("day","2026-09-18")
            .put("source",JSONObject().put("kind","whoop_import").put("externalDeviceId","export").put("method","vendor_daily"))
            .put("values",JSONObject().put("sleep_need_min",JSONObject().put("value",need).put("unit","min"))
                .put("sleep_performance_pct",JSONObject().put("value",91).put("unit","%"))
                .put("sleep_consistency_pct",JSONObject().put("value",87).put("unit","%"))))
        val i=input("2026-09-18",listOf(imported(480)))
        val (commit,d)=evaluate(i,result(i));val without=evaluate(input(i.day),result(i))
        assertEquals(91.0,d.metrics.getJSONObject("sleep_performance").getDouble("value"),0.0)
        assertEquals(87.0,d.metrics.getJSONObject("sleep_consistency").getDouble("value"),0.0)
        assertEquals(87.5,d.metrics.getJSONObject("hours_vs_needed_pct").getDouble("value"),0.0)
        assertEquals(without.first.sleepDebt,commit.sleepDebt)
        assertTrue(without.first.state.getJSONObject("baselinesAfter").similar(commit.state.getJSONObject("baselinesAfter")))
        val zero=input(i.day,listOf(imported(0)))
        assertTrue(evaluate(zero,result(zero)).second.metrics.getJSONObject("hours_vs_needed_pct").isNull("value"))
        val unknown=input(i.day,listOf(imported(JSONObject.NULL)))
        assertEquals("descriptive_mean_need_floor_450",evaluate(unknown,result(unknown)).second.metrics.getJSONObject("hours_vs_needed_pct").getString("method"))
    }

    @Test fun manualWorkoutWithoutRawHasIdentityAndBoundsButNoInventedPhysiology() {
        val base=input("2026-09-18"); val start=base.dayLo+15*3600
        val edit=HistoryInputReader.Input("manual_workout","workout:40000000-0000-4000-8000-000000000001",3,false,JSONObject()
            .put("start",start).put("end",start+3600).put("originalStart",start).put("originalSport","strength")
            .put("sport","strength").put("dismissed",false).put("energyKcal",JSONObject.NULL).put("distanceM",JSONObject.NULL).put("steps",JSONObject.NULL))
        val input=base.copy(hr=emptyList(),history=HistoryInputReader.Day(base.history.values+edit))
        val (_,d)=evaluate(input,result(input))
        val workout=d.details.getJSONArray("workouts").getJSONObject(0)
        assertEquals(edit.entity,workout.getString("editEntity"))
        for(key in listOf("avgHr","peakHr","strain","energyKcal","hrCoveragePct","zoneSeconds")) assertTrue(key,workout.isNull(key))
        assertEquals(60.0,d.metrics.getJSONObject("strength_min").getDouble("value"),0.0)
        assertEquals(1,d.metrics.getJSONObject("exercise_count").getInt("value"))
    }

    @Test fun contextFactoryRetainsPerDayBaselineAndExplicitPersonalMode() {
        val first=input("2026-09-17"); val done=evaluate(first,result(first)).first
        val config=HistoryInputReader.Input("config","primary",3,false,JSONObject().put("daytimePersonalBaselineEnabled",true))
        val next=input("2026-09-18",listOf(config))
        val p=HistoricalStateMachine.prepare(next,HistoryCheckpointReader.Seed(done.state,listOf(done.state.getJSONObject("observation"))))
        val context=HistoricalContextInputFactory.build(next,result(next),p)
        assertTrue(context.daytimePersonalBaselineEnabled)
        assertEquals(0,context.history.first().baselinesBefore.getValue("hrv").nValid)
        assertEquals(1,context.history.last().baselinesBefore.getValue("hrv").nValid)
        assertTrue(context.hourlyHr.all { it.start<=next.dayHi })
    }

    @Test fun customDisplayZonesAndManualStepCalibrationCallExistingEnginesWithoutChangingMeasuredSteps() {
        val config=HistoryInputReader.Input("config","primary",3,false,JSONObject()
            .put("customHRZoneLowerBounds",org.json.JSONArray(listOf(60,70,80,90,100))).put("stepsManualCoefficient",42.5))
        val base=input("2026-09-18",listOf(config))
        val input=base.copy(gravity=listOf(GravitySample(source,base.dayLo,0.0,0.0,1.0),GravitySample(source,base.dayLo+30,0.0,1.0,0.0)))
        val (commit,d)=evaluate(input,result(input))
        val zones=HrZones.zones(age=input.profile.age,customLowerBounds=listOf(60.0,70.0,80.0,90.0,100.0))
        val expected=HrZones.timeInZone(input.hr,zones)
        assertEquals("custom",d.details.getJSONObject("hr_zones").getString("source"))
        assertEquals(expected.seconds.take(3).sum()/60,d.metrics.getJSONObject("hr_zones13_min").getDouble("value"),0.0)
        assertTrue(d.details.getJSONObject("step_calibration").getBoolean("manual"))
        val motion=commit.state.getJSONObject("observation").getDouble("dayMotion")
        assertEquals(StepsEstimateEngine.estimate(motion,StepsEstimateEngine.calibrate(emptyList(),42.5)!!),d.metrics.getJSONObject("steps_est").getInt("value"))
        assertEquals(9000,d.metrics.getJSONObject("steps").getInt("value"))
    }

    @Test fun candidateIsExplicitlyOptedInAndNeverPromotedToMeasuredOxygen() {
        val base=input("2026-09-18")
        val aux=listOf(V18AuxRow(base.dayLo+30,auxByte82=95),V18AuxRow(base.dayLo+60,auxByte82=98),
            V18AuxRow(base.dayLo+90,auxByte82=120),V18AuxRow(base.dayLo+12*3600,auxByte82=70))
        val off=base.copy(v18Aux=aux)
        assertFalse(evaluate(off,result(off)).second.capabilities.contains("spo2_candidate"))
        val config=HistoryInputReader.Input("config","primary",3,false,JSONObject().put("spo2CandidateDisplayEnabled",true))
        val on=off.copy(history=HistoryInputReader.Day(off.history.values+config))
        val derived=evaluate(on,result(on)).second
        assertEquals(97,derived.metrics.getJSONObject("spo2_candidate").getInt("value"))
        assertEquals("experimental",derived.metrics.getJSONObject("spo2_candidate").getString("status"))
        assertTrue(derived.metrics.getJSONObject("spo2_pct").isNull("value"))
        assertFalse(derived.details.getJSONObject("spo2_candidate").getBoolean("validated"))
        assertEquals(2,derived.details.getJSONObject("spo2_candidate").getInt("sampleCount"))
    }

    @Test fun sessionChartsUseStableIdentityAndMovementNotConstantGravityMagnitude() {
        val base=input("2026-09-18")
        val input=base.copy(gravity=List(8) { GravitySample(source,base.dayLo+it*30,0.0,0.0,1.0) })
        val r=result(input).copy(sessionMotionByStart=mapOf(input.dayLo to List(960) { 0.0 }),
            sessionSleepStateByStart=mapOf(input.dayLo to List(960) { 2 }))
        val p=HistoricalStateMachine.prepare(input,HistoryCheckpointReader.Seed(null,emptyList()))
        val commit=HistoricalStateMachine.finish(input,r,p,emptyMap())
        val identity=SleepIdentity(input.dayLo-3600,input.dayLo+7*3600,"sleep:40000000-0000-4000-8000-000000000001")
        val d=ServerMetricOrchestrator.evaluate(input,r,commit,mapOf(SleepBounds(input.dayLo,input.dayLo+8*3600) to identity))
        assertEquals(0.0,d.charts.getJSONArray("sleep_motion:${identity.id}").getJSONObject(0).getDouble("value"),0.0)
        assertTrue(d.charts.has("sleep_hr:${identity.id}"))
        val detail=d.details.getJSONArray("sleep_sessions").getJSONObject(0)
        assertEquals(identity.id,detail.getString("id"))
        assertTrue(detail.getJSONObject("motion").getJSONArray("values").isNull(8))
        assertEquals(0.0,detail.getJSONObject("motion").getJSONArray("values").getDouble(0),0.0)
        assertFalse(detail.getJSONObject("bandState").getBoolean("isDerivedStage"))
    }
}
