package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.*
import org.json.JSONArray
import org.json.JSONObject
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters
import kotlin.math.exp
import kotlin.math.sqrt

data class ServerDerivedMetrics(
    val metrics: JSONObject = JSONObject(), val details: JSONObject = JSONObject(),
    val charts: JSONObject = JSONObject(), val chartMetadata: JSONObject = JSONObject(),
    val history: JSONArray = JSONArray(), val gaps: Set<String> = emptySet(),
    val capabilities: Set<String> = metrics.keySet()+details.keySet()+charts.keySet(),
) {
    fun withContext(context:HistoricalContextResult):ServerDerivedMetrics {
        for(key in context.metrics.keySet()) {
            require(!metrics.has(key)) { "duplicate_metric_owner:$key" }
            val reading=context.metrics.getJSONObject(key)
            if(!reading.has("status")) reading.put("status",if(reading.isNull("value")) "unavailable" else "available")
            metrics.put(key,reading)
        }
        for(key in context.details.keySet()) { require(!details.has(key)); details.put(key,context.details.get(key)) }
        for(key in context.charts.keySet()) {
            require(!charts.has(key))
            val source=context.charts.getJSONArray(key)
            charts.put(key,JSONArray((maxOf(0,source.length()-180) until source.length()).map { source.get(it) }))
            chartMetadata.put(key,JSONObject().put("schemaVersion",1).put("method","existing_context_engine"))
        }
        return copy(gaps=gaps+context.gaps,capabilities=capabilities+context.capabilities)
    }
}

/** Adapts existing kernel engines and existing Swift presentation formulas; never reads current time. */
object ServerMetricOrchestrator {
    fun evaluate(input: SignalSampleReader.DayInputs, result: DayResult, commit: HistoricalStateMachine.Commit,
                 sleepIdentities:Map<SleepBounds,SleepIdentity> = emptyMap(),napOverrides:Map<SleepBounds,Boolean> = emptyMap(),
                 cycle:DayCycleMetricOrchestrator.Result? = null): ServerDerivedMetrics {
        val metrics=JSONObject(); val details=JSONObject(); val charts=JSONObject(); val metadata=JSONObject()
        val gaps=linkedSetOf<String>(); val d=result.daily; val p=commit.prepared
        if(cycle!=null) { details.put("day_cycle",cycle.details(input.day)); gaps+=cycle.gaps }
        input.scalarInputs?.let { scalars ->
            details.put("input_provenance",scalars.diagnostics(input.nightLo,input.nightHi))
            gaps+=scalars.gaps
            val derived=scalars.derivedWithoutMeasuredOverlap(input.hr).filter { it.ts in input.dayLo..input.dayHi }
            details.put("derived_ppg_hr",JSONObject().put("method","uploaded_ppg_estimate_not_measured_hr")
                .put("admittedToNightPhysiology",false).put("usedForRrHrv",false)
                .put("samplesAfterMeasuredOverlap",derived.size).put("unknownConfidence",derived.count { it.confidence==null }))
            charts.put("derived_ppg_hr",JSONArray(derived.groupBy { input.dayLo+Math.floorDiv(it.ts-input.dayLo,300)*300 }.toSortedMap().map { (start,rows) ->
                JSONObject().put("start",start).put("end",minOf(input.dayHi+1,start+300)).put("value",rows.map { it.bpm }.average())
                    .put("count",rows.size).put("min",rows.minOf { it.bpm }).put("max",rows.maxOf { it.bpm })
            }))
            metadata.put("derived_ppg_hr",JSONObject().put("schemaVersion",1).put("unit","bpm").put("bucketSeconds",300)
                .put("method","uploaded_ppg_estimate_observed_mean").put("measured",false).put("measuredHrWinsOverlap",true))
        }
        val rows=p.history.map { DailyMetricJson.decode(it.getJSONObject("daily")) }+d
        val config=input.history.configuration
        val profile=input.history.profile?.takeUnless { it.deleted }?.payload ?: JSONObject()
        fun metric(key:String,value:Number?,unit:String,method:String,status:String?=null) {
            metrics.put(key,JSONObject().put("value",value ?: JSONObject.NULL).put("unit",unit)
                .put("status",status ?: if(value==null) "unavailable" else "available").put("method",method))
        }
        fun nullable(key:String)=if(config.isNull(key)) null else config.getDouble(key)
        metric("hrv_rmssd_ms",d.avgHrv,"ms","nightly_rr_rmssd")
        metric("hrv_sdnn_ms",d.avgSdnn,"ms","nightly_rr_sdnn")
        metric("resting_hr_bpm",d.restingHr,"bpm","nightly_rolling_floor")
        metric("resp_rate_bpm",d.respRateBpm,"breaths/min","nightly_respiration")
        metric("recovery",result.recovery,"score_0_100","charge_ewma_asof")
        metric("strain",result.strain,"score_0_100","${if(cycle?.usesCalendar==false) "asof_cycle" else "daily"}_${p.effortMethod.lowercase()}")
        metric("exercise_count",if(input.hr.isEmpty()) null else result.workouts.size,"count","workout_detector")
        metric("steps",d.steps,"count",if(cycle?.usesCalendar==false) "asof_cycle_sleep_aware_counter" else "strap_counter_calibrated_ticks")
        metric("active_kcal_est",d.activeKcalEst,"kcal",if(cycle?.usesCalendar==false) "asof_cycle_hr_energy_estimate" else "hr_energy_estimate")
        metric("spo2_pct",d.spo2Pct,"percent","measured_percentage")
        metric("spo2_red",d.spo2Red,"adc","raw_red_adc")
        metric("spo2_ir",d.spo2Ir,"adc","raw_ir_adc")
        if(config.optBoolean("spo2CandidateDisplayEnabled",false)) {
            val candidate=if(input.isOura) AnalyticsEngine.nightlySpo2CeilingMean(result.sleepSessions,input.spo2)
                else AnalyticsEngine.nightlySpo2CandidateMean(result.sleepSessions,input.v18Aux)
            val candidateMethod=if(input.isOura) "experimental_oura_0x6f_ceiling_100_mean" else "experimental_v18_aux82_plausibility_mean"
            metric("spo2_candidate",candidate?.first,"percent",candidateMethod,
                if(candidate==null) "unavailable" else "experimental")
            details.put("spo2_candidate",JSONObject().put("method",candidateMethod)
                .put("validated",false).put("sampleCount",candidate?.second ?: 0).put("sourceDeviceId",input.deviceId)
                .put("identityPolicy",if(input.isOura) "timestamp" else "timestamp_optional_record_index")
                .put("aggregationPolicy","existing_record_weighted_plausible_mean"))
            if(candidate==null) gaps+="spo2_candidate_observations_unavailable"
        }
        gaps+=input.auxiliaryGaps
        metric("skin_temp_c",result.nightlySkinTempC,"C","${if(input.isOura) "oura" else input.deviceFamily.name.lowercase()}_worn_skin")
        metric("skin_temp_dev_c",d.skinTempDevC,"C","personal_skin_baseline_deviation")
        details.put("skin_calibration",JSONObject().put("family",if(input.isOura) "oura" else input.deviceFamily.name.lowercase())
            .put("anchorRaw",p.skinTempAnchorRaw ?: JSONObject.NULL).put("asOfDay",input.day)
            .put("method",if(input.deviceFamily==com.noop.protocol.DeviceFamily.WHOOP4) "asof_21_day_window_worn_raw_median" else "centidegree_raw")
            .put("priorThermalBaselineCommonScale",input.deviceFamily==com.noop.protocol.DeviceFamily.WHOOP4)
            .put("relative",input.deviceFamily==com.noop.protocol.DeviceFamily.WHOOP4))
        metric("sleep_total_min",d.totalSleepMin,"min","main_night_stages")
        metric("sleep_light_min",d.lightMin,"min","main_night_stages")
        metric("sleep_deep_min",d.deepMin,"min","main_night_stages")
        metric("sleep_rem_min",d.remMin,"min","main_night_stages")
        metric("sleep_efficiency",d.efficiency?.times(100),"percent","observed_asleep_over_in_bed")
        metric("disturbances",d.disturbances,"count","main_night_stages")
        metric("sleep_performance",result.rest,"score_0_100","rest_composite_asof")
        metric("sleep_need_min",p.needHours*60,"min","normative_upper_quartile_age_floor")
        val descriptiveNeed=maxOf(450.0,rows.dropLast(1).mapNotNull { it.totalSleepMin?.takeIf { v -> v>0 } }.meanOrNull() ?: 450.0)
        metric("hours_vs_needed_pct",d.totalSleepMin?.takeIf { it>0 }?.let { it/descriptiveNeed*100 },"percent","descriptive_mean_need_floor_450")
        val restorative=if(d.deepMin!=null && d.remMin!=null) d.deepMin!!+d.remMin!! else null
        metric("restorative_min",restorative,"min","deep_plus_rem")
        metric("restorative_pct",if(restorative!=null && (d.totalSleepMin ?: 0.0)>0) restorative/d.totalSleepMin!!*100 else null,"percent","deep_plus_rem_over_asleep")
        metric("sleep_debt_min",commit.sleepDebt.takeIf { it.nightCount>0 }?.magnitudeMin,"min","sleep_debt_14_usable_nights")
        val bedMinutes=(p.history+commit.state.getJSONObject("observation")).flatMap { row ->
            val zone=ZoneId.of(row.getString("timezone")); val blocks=row.getJSONArray("sleepBlocks")
            (0 until blocks.length()).map { i ->
                val local=Instant.ofEpochSecond(blocks.getJSONObject(i).getLong("start")).atZone(zone)
                val m=(local.hour*60+local.minute).toDouble(); if(m<720) m+1440 else m
            }
        }.takeLast(14)
        metric("sleep_consistency",bedMinutes.takeIf { it.size>=3 }?.let {
            (100*(1-populationSD(it)/120)).coerceIn(0.0,100.0)
        },"percent","rolling_14_bedtime_spread")
        details.put("sleep_ledger",JSONObject().put("needMin",commit.sleepDebt.needMin).put("balanceMin",commit.sleepDebt.balanceMin)
            .put("nightCount",commit.sleepDebt.nightCount).put("descriptiveNeedMin",descriptiveNeed)
            .put("restDurationConsistency",p.consistency ?: JSONObject.NULL).put("habitualMidsleepSec",p.habitualMidsleep ?: JSONObject.NULL)
            .put("nights",JSONArray(commit.sleepDebt.nights.map { JSONObject().put("day",it.day).put("sleptMin",it.sleptMin).put("deltaMin",it.deltaMin) })))
        details.put("sleep_typicals",JSONObject().put("method","strictly_prior_observed_nights")
            .put("asleepMin",rows.dropLast(1).mapNotNull { it.totalSleepMin?.takeIf { v -> v>0 } }.meanOrNull() ?: JSONObject.NULL)
            .put("deepMin",rows.dropLast(1).mapNotNull { it.deepMin?.takeIf { v -> v>0 } }.meanOrNull() ?: JSONObject.NULL)
            .put("remMin",rows.dropLast(1).mapNotNull { it.remMin?.takeIf { v -> v>0 } }.meanOrNull() ?: JSONObject.NULL)
            .put("lightMin",rows.dropLast(1).mapNotNull { it.lightMin?.takeIf { v -> v>0 } }.meanOrNull() ?: JSONObject.NULL))

        val baselineDetails=HistoricalStateMachine.encodeBaselines(p.baselines)
        val values=mapOf("hrv" to d.avgHrv,"resting_hr" to d.restingHr?.toDouble(),"resp" to d.respRateBpm,"skin_temp" to result.nightlySkinTempC)
        for((key,state) in p.baselines) {
            val value=values[key]
            val deviation=value?.takeIf { state.usable }?.let { Baselines.deviation(it,state) }
            baselineDetails.getJSONObject(key).put("z",deviation?.z ?: JSONObject.NULL)
                .put("delta",deviation?.delta ?: JSONObject.NULL).put("ratio",deviation?.ratio ?: JSONObject.NULL)
                .put("normalLow",state.baseline-Baselines.sigma(state)).put("normalHigh",state.baseline+Baselines.sigma(state))
        }
        details.put("baselines",baselineDetails)
        val drivers=if(d.avgHrv!=null && d.restingHr!=null && p.baselines["hrv"]!=null)
            RecoveryDrivers.chargeDrivers(d.avgHrv!!,d.restingHr!!.toDouble(),d.respRateBpm,p.baselines.getValue("hrv"),
                p.profileBaselines.restingHR,p.profileBaselines.resp,result.rest?.div(100) ?: d.efficiency,d.skinTempDevC) else emptyList()
        details.put("charge",JSONObject().put("confidence",result.chargeConfidence.name.lowercase()).put("drivers",JSONArray(drivers.map {
            JSONObject().put("key",it.label.name.lowercase()).put("deltaPoints",it.deltaPoints).put("value",it.value)
                .put("baseline",it.baseline ?: JSONObject.NULL).put("unit",it.unit.name.lowercase()).put("verdict",it.verdict.name.lowercase())
        })))
        details.put("effort",JSONObject().put("confidence",result.effortConfidence.name.lowercase()).put("method",p.effortMethod))
        details.put("rest",JSONObject().put("confidence",result.restConfidence.name.lowercase()).put("gravitySparse",result.gravitySparse)
            .put("hrOnly",d.sleepHrOnly ?: JSONObject.NULL))
        details.put("sleep_sessions",SleepResultDetails.build(input,result,p,sleepIdentities,napOverrides))
        details.put("workout_detection",result.detectionFunnel?.let { f -> JSONObject()
            .put("hrSamples",f.hrSamples).put("motionSamples",f.motionSamples).put("restingHR",f.restingHR ?: JSONObject.NULL)
            .put("hrFloor",f.hrFloor ?: JSONObject.NULL).put("motionPassed",f.motionPassed).put("hrMissing",f.hrMissing)
            .put("hrTooLow",f.hrTooLow).put("active",f.active).put("runs",f.runs).put("bridged",f.bridged)
            .put("longestRunS",f.longestRunS).put("meanRunS",f.meanRunS).put("droppedShort",f.droppedShort)
            .put("droppedNoHR",f.droppedNoHR).put("droppedLowIntensity",f.droppedLowIntensity).put("kept",f.kept)
        } ?: JSONObject.NULL)

        val admission=HistoricalMetricAdmission(p,d)
        val loadRows=admission.rows
        val readiness=ReadinessEngine.evaluateCalendar(admission.readinessRows(),input.day)
        val training=TrainingLoadEngine.evaluate(loadRows.map { TrainingLoadEngine.DailyLoad(it.day,it.strain) },input.day)
        details.put("readiness",JSONObject().put("level",readiness.level.name.lowercase()).put("confidence",readiness.confidence.name.lowercase())
            .put("headline",readiness.headlineRes.name.lowercase()).put("summary",readiness.summaryRes.name.lowercase())
            .put("signals",JSONArray(readiness.signals.map { signal ->
                val evidence=when(val e=signal.evidence) {
                    is ReadinessEngine.Evidence.MetricVsBaseline -> JSONObject().put("kind","metric_vs_baseline").put("value",e.value).put("baseline",e.baseline).put("unit",e.unit.name.lowercase()).put("decimals",e.decimals)
                    is ReadinessEngine.Evidence.Monotony -> JSONObject().put("kind","monotony").put("value",e.value)
                    is ReadinessEngine.Evidence.TrainingLoad -> JSONObject().put("kind","training_load").put("acute",e.acute).put("chronic",e.chronic)
                    null -> JSONObject.NULL
                }
                JSONObject().put("key",signal.key).put("flag",signal.flag.name.lowercase()).put("label",signal.labelRes.name.lowercase())
                    .put("detail",signal.detailRes.name.lowercase()).put("evidence",evidence)
            })))
        metric("acwr",readiness.acwr,"ratio","readiness_7_28_calendar_suffix")
        metric("training_monotony",readiness.monotony,"ratio","foster_calendar_suffix_week")
        metric("chronic_load",training.chronicLoad,"score_0_100","ewma_42d_${p.effortMethod.lowercase()}")
        metric("acute_load",training.acuteLoad,"score_0_100","ewma_7d_${p.effortMethod.lowercase()}")
        metric("training_balance",training.balance,"score_delta","chronic_minus_acute")
        details.put("training_load",JSONObject().put("state",training.state.name.lowercase()).put("unavailableReason",training.unavailableReason?.name?.lowercase() ?: JSONObject.NULL)
            .put("contiguousDays",training.contiguousDays).put("points",JSONArray(training.points.takeLast(180).map {
                JSONObject().put("day",it.day).put("load",it.load).put("chronic",it.chronicLoad).put("acute",it.acuteLoad).put("balance",it.balance)
            })))

        val seven=admission.window(7); val rhrs=seven.mapNotNull { it.restingHr?.toDouble() }
        val active=seven.mapNotNull { it.strain }.filter { it>=30 }
        val age=profile.number("age"); val sex=profile.optString("sex","")
        val ready=FitnessAgeEngine.assessReadiness(age!=null,sex.isNotEmpty(),rhrs.size,seven.count { it.strain!=null },
            profile.number("heightCm")!=null && profile.number("weightKg")!=null,profile.number("waistCm")!=null)
        val hasCurrentFitness=admission.today.restingHr!=null || admission.today.strain!=null
        val fitness=if(ready.canCompute && hasCurrentFitness) FitnessAgeEngine.compute(age!!,sex,median(rhrs)!!,
            FitnessAgeEngine.physicalActivityIndexFromStrain(active.size,active.meanOrNull() ?: 0.0),profile.number("waistCm")) else null
        val vo2=fitness?.vo2max ?: fitness?.let { Calories.vo2maxFor(StrainScorer.estimateHRmax(emptyList(),age).first,median(rhrs)) }
        metric("fitness_age",fitness?.fitnessAge,"years","nes_hunt_activity")
        metric("vo2max_est",vo2,"mL/kg/min",if(fitness?.vo2max!=null) "nes_waist" else "uth_hr_ratio")
        val weeklyKey=LocalDate.parse(input.day).with(TemporalAdjusters.previousOrSame(DayOfWeek.SATURDAY)).toString()
        details.put("fitness_age",JSONObject().put("weekKey",weeklyKey).put("asOfDay",input.day).put("confidence",ready.confidence.name.lowercase())
            .put("bandYears",FitnessAgeEngine.displayBandYears).put("lowerConfidence",fitness?.lowerConfidence ?: true)
            .put("inputs",JSONArray(ready.items.map { JSONObject().put("key",it.key).put("status",it.status.name.lowercase()).put("required",it.required).put("role",it.role.name.lowercase()) })))
        val sleepHours=seven.mapNotNull { it.totalSleepMin?.takeIf { v -> v>0 }?.div(60) }
        val hasCurrentVitality=with(admission.today) { restingHr!=null || avgHrv!=null || totalSleepMin!=null || steps!=null }
        val vitality=age?.takeIf { hasCurrentVitality }?.let { VitalityEngine.compute(VitalityEngine.Inputs(it,restingHR=median(rhrs),sleepHours=sleepHours.meanOrNull(),
            sleepConsistency=VitalityEngine.sleepConsistency(sleepHours),rmssd=median(seven.mapNotNull { row -> row.avgHrv }),
            rmssdNorm=VitalityEngine.rmssdNorm(it),steps=seven.mapNotNull { row -> row.steps?.toDouble() }.meanOrNull())) }
        metric("vitality",vitality?.vitality,"score_0_100","vitality_existing_hazard_model")
        metric("body_age",vitality?.bodyAge,"years","vitality_existing_hazard_model")
        details.put("vitality",JSONObject().put("weekKey",weeklyKey).put("asOfDay",input.day).put("factorsUsed",vitality?.factorsUsed ?: 0)
            .put("bandYears",VitalityEngine.bandYears).put("contributions",JSONArray(vitality?.contributions?.map {
                JSONObject().put("key",it.key).put("lnHazard",it.lnHazard)
            } ?: emptyList<JSONObject>())))

        val hr=input.hr.filter { it.ts in input.dayLo..input.dayHi && it.bpm>0 }
        metric("avg_hr",hr.map { it.bpm.toDouble() }.meanOrNull(),"bpm","calendar_day_observed_hr")
        metric("max_hr",hr.maxOfOrNull { it.bpm },"bpm","calendar_day_observed_hr")
        val zoneSet=ScoringPreferences.displayZones(input.profile.age,config)
        val zoneTime=hr.takeIf { it.isNotEmpty() }?.let { HrZones.timeInZone(it,zoneSet) }
        metric("hr_zones13_min",zoneTime?.seconds?.take(3)?.sum()?.div(60),"min","hrmax_display_zones")
        metric("hr_zones45_min",zoneTime?.seconds?.drop(3)?.sum()?.div(60),"min","hrmax_display_zones")
        metric("hr_zones_all_min",zoneTime?.seconds?.sum()?.div(60),"min","hrmax_display_zones")
        details.put("hr_zones",JSONObject().put("maxHR",zoneSet.maxHR).put("source",zoneSet.source)
            .put("lowerBounds",JSONArray(zoneSet.zones.map { it.lower }))
            .put("seconds",zoneTime?.let { JSONArray(it.seconds) } ?: JSONObject.NULL))
        val workouts=WorkoutResultOrchestrator.evaluate(input,result,cycle)
        metric("exercise_count",workouts.count,"count","resolved_workout_set")
        metric("strength_min",workouts.strengthMin,"min","explicit_strength_workout_bounds")
        details.put("workouts",workouts.sessions); gaps+=workouts.gaps
        val workoutSports=(0 until workouts.sessions.length()).map { workouts.sessions.getJSONObject(it).optString("sport","Activity") }
            .distinct().sorted()
        commit.state.getJSONObject("observation").put("workoutSports",JSONArray(workoutSports))
        val activityDays=linkedMapOf<String,MutableSet<String>>()
        for(row in p.history+commit.state.getJSONObject("observation")) {
            val sports=row.optJSONArray("workoutSports") ?: continue
            for(i in 0 until sports.length()) activityDays.getOrPut(sports.getString(i)) { sortedSetOf() }.add(row.getString("day"))
        }
        val recoveryByDay=rows.mapNotNull { row -> row.recovery?.let { row.day to it } }.toMap()
        details.put("activity_cost",JSONArray(ActivityCostEngine.evaluate(activityDays,recoveryByDay).map {
            JSONObject().put("sport",it.sport).put("delta",it.delta).put("meanNextMorning",it.meanNextMorning)
                .put("baselineMean",it.baselineMean).put("daysToBaseline",it.daysToBaseline ?: JSONObject.NULL)
                .put("sampleDays",it.n).put("confidence",it.confidence.name.lowercase())
        }))

        val imported=ImportedMetricResolver.resolve(input)
        val importedOutputs=mapOf("steps_count" to "steps","active_energy_kcal" to "active_kcal_est","basal_energy_kcal" to "basal_energy_kcal",
            "spo2_pct" to "spo2_pct","sleep_debt_min" to "sleep_debt_min","vo2max_ml_kg_min" to "vo2max_measured",
            "body_mass_kg" to "body_mass_kg","lean_mass_kg" to "lean_mass_kg","body_fat_pct" to "body_fat_pct","bmi_kg_m2" to "bmi_kg_m2",
            "sleep_performance_pct" to "sleep_performance","sleep_consistency_pct" to "sleep_consistency","sleep_need_min" to "sleep_need_min")
        val provenance=JSONObject()
        val sourceOnly=setOf("avg_hr_bpm","resting_hr_bpm","hrv_rmssd_ms","hrv_sdnn_ms","resp_rate_bpm","skin_temp_c","sleep_total_min",
            "miband_max_hr_bpm","miband_vitality_points","miband_sleep_deep_min","miband_sleep_rem_min",
            "miband_sleep_light_min","miband_sleep_awake_min","miband_intensity_min","miband_sleep_score_0_100","miband_stress_score_0_100")
        for(key in sourceOnly.sorted()) imported[key]?.let { r ->
            val outputKey="imported_$key"
            metric(outputKey,r.value,if(r.unit=="%") "percent" else r.unit,"imported:${r.source.getString("kind")}:${r.source.getString("method")}")
            provenance.put(outputKey,JSONObject().put("source",r.source).put("inputRevision",r.revision))
        }
        for((inputKey,mappedKey) in importedOutputs) imported[inputKey]?.let { r ->
            val outputKey=if(cycle?.usesCalendar==false && inputKey in setOf("steps_count","active_energy_kcal")) "imported_calendar_$inputKey" else mappedKey
            val unit=if(r.unit=="%") "percent" else r.unit
            metric(outputKey,r.value,unit,"imported:${r.source.getString("kind")}:${r.source.getString("method")}")
            provenance.put(outputKey,JSONObject().put("source",r.source).put("inputRevision",r.revision))
        }
        imported["sleep_need_min"]?.let { r ->
            metric("hours_vs_needed_pct",d.totalSleepMin?.takeIf { it>0 && r.value>0 }?.let { it/r.value*100 },
                "percent","observed_asleep_over_imported_need")
            provenance.put("hours_vs_needed_pct",JSONObject().put("denominatorSource",r.source).put("inputRevision",r.revision))
        }
        details.put("imported_provenance",provenance)
        val calibration=p.history.filter { it.getString("day")>=LocalDate.parse(input.day).minusDays(60).toString() }.mapNotNull { row ->
            val reading=ImportedMetricResolver.resolve(input,row.getString("day"))["steps_count"]
                ?.takeIf { it.source.getString("kind") in setOf("apple_health","health_connect") }
            val motion=row.number("dayMotion")
            if(reading!=null && motion!=null) StepsEstimateEngine.CalibrationPoint(motion,reading.value) else null
        }
        val stepFit=StepsEstimateEngine.calibrate(calibration,ScoringPreferences.manualSteps(config))
        val motion=commit.state.getJSONObject("observation").getDouble("dayMotion")
        metric("steps_est",stepFit?.let { StepsEstimateEngine.estimate(motion,it) },"count","personal_motion_phone_steps_calibration")
        details.put("step_calibration",JSONObject().put("sampleDays",stepFit?.sampleDays ?: calibration.size)
            .put("coefficient",stepFit?.coefficient ?: JSONObject.NULL).put("confidence",stepFit?.confidence ?: JSONObject.NULL)
            .put("manual",stepFit?.manual ?: false).put("dayMotion",motion))
        // StressView.StressMath formula, restricted to eligible observations in the prior 30 calendar slots.
        val previous=admission.window(30,includeToday=false)
        val rhrHistory=previous.mapNotNull { it.restingHr?.toDouble() }; val hrvHistory=previous.mapNotNull { it.avgHrv }
        val current=admission.today
        val canStress=(current.restingHr!=null && rhrHistory.isNotEmpty()) || (current.avgHrv!=null && hrvHistory.isNotEmpty())
        var stressZ=0.0
        if(current.restingHr!=null && populationSD(rhrHistory)>0.0001) stressZ+=(current.restingHr!!-rhrHistory.average())/populationSD(rhrHistory)
        if(current.avgHrv!=null && populationSD(hrvHistory)>0.0001) stressZ+=(hrvHistory.average()-current.avgHrv!!)/populationSD(hrvHistory)
        metric("stress",if(canStress) 3.0/(1+exp(-stressZ)) else null,"score_0_3","daily_prior30_rhr_hrv_zsum")

        fun chart(key:String,unit:String,points:List<Pair<Long,Double>>,lo:Long,hi:Long) {
            val width=300L
            charts.put(key,JSONArray(points.filter { it.first in lo until hi && it.second.isFinite() }.groupBy {
                lo+Math.floorDiv(it.first-lo,width)*width
            }.toSortedMap().map { (start,values) -> JSONObject().put("start",start).put("end",minOf(hi,start+width))
                .put("value",values.map { it.second }.average()).put("count",values.size)
                .put("min",values.minOf { it.second }).put("max",values.maxOf { it.second }) }))
            metadata.put(key,JSONObject().put("schemaVersion",1).put("unit",unit).put("bucketSeconds",width).put("method","observed_mean_min_max"))
        }
        chart("day_hr","bpm",hr.map { it.ts to it.bpm.toDouble() },input.dayLo,input.dayHi+1)
        for(s in result.sleepSessions) {
            val identity=sleepIdentities[SleepBounds(s.start,s.end)] ?: SleepIdentity.detected(input.userId,input.deviceId,s.start,s.end)
            val key="sleep_hr:${identity.id}"
            chart(key,"bpm",input.hr.map { it.ts to it.bpm.toDouble() },s.start,s.end)
            chart("sleep_motion:${identity.id}","gravity_delta",WorkoutDetector.activitySeries(input.gravity.filter { it.ts in s.start until s.end })
                .map { it.ts to it.intensity },s.start,s.end)
            metadata.getJSONObject(key).put("sessionId",identity.id)
            metadata.getJSONObject("sleep_motion:${identity.id}").put("sessionId",identity.id).put("signal","consecutive_gravity_l2_delta")
        }
        // History is stored when its own day is scored, never recomputed with today's profile/baseline.
        val history=JSONArray(p.history.takeLast(30).mapNotNull { row -> row.optJSONObject("metrics")?.let {
            JSONObject().put("day",row.getString("day")).put("metrics",it)
        } })
        commit.state.getJSONObject("observation").put("metrics",metrics)
        if(profile.isNull("age") || profile.isNull("sex")) gaps+="longevity_profile_incomplete"
        return ServerDerivedMetrics(metrics,details,charts,metadata,history,gaps)
    }

    private fun JSONObject.number(key:String):Double?=if(isNull(key)) null else getDouble(key)
    private fun List<Double>.meanOrNull():Double?=if(isEmpty()) null else average()
    private fun median(xs:List<Double>):Double? {
        if(xs.isEmpty()) return null
        val sorted=xs.sorted(); val m=sorted.size/2
        return if(sorted.size%2==0) (sorted[m-1]+sorted[m])/2 else sorted[m]
    }
    private fun populationSD(xs:List<Double>):Double {
        if(xs.size<2) return 0.0
        val mean=xs.average(); return sqrt(xs.sumOf { (it-mean)*(it-mean) }/xs.size)
    }
}
