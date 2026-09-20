package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.*
import org.json.JSONArray
import org.json.JSONObject
import java.nio.charset.StandardCharsets
import java.time.Instant
import java.time.ZoneId
import java.util.UUID

/** Complete source-local workout set. User bounds are inputs; measured physiology is always rescored. */
object WorkoutResultOrchestrator {
    data class Result(val sessions:JSONArray,val count:Int?,val strengthMin:Double?,val gaps:Set<String>)
    private data class Entry(val entity:String,val payload:JSONObject,val manual:Boolean,val legacySource:String? = null)
    fun evaluate(input:SignalSampleReader.DayInputs,result:DayResult,cycle:DayCycleMetricOrchestrator.Result? = null):Result {
        val config=input.history.configuration
        val method=StrainScorer.Method.valueOf(config.optString("effortMethod","EDWARDS"))
        val manual=input.history.values.filter { it.kind=="manual_workout" && !it.deleted }.sortedByDescending { it.revision }
        val lo=cycle?.window?.startInclusive ?: input.dayLo
        val hi=cycle?.window?.endExclusive ?: input.dayHi+1
        val ownsDay=cycle?.appliesToDay != false
        val future=manual.filter { !it.payload.getBoolean("dismissed") && it.payload.getLong("start") in lo until hi && it.payload.getLong("end")>input.dayHi+1 }
        val journal=manual.filter { ownsDay && !it.payload.getBoolean("dismissed") && it.payload.getLong("start") in lo until hi && it.payload.getLong("end")<=input.dayHi+1 }
            .map { Entry(it.entity,it.payload,true) }
        // Explicit journal edits replace their original uploaded key even when moved/dismissed.
        val legacy=input.legacyWorkouts.filter { w -> ownsDay && w.start in lo until hi && manual.none {
            it.entity=="workout:${w.id}" || (it.payload.getLong("originalStart")==w.start && it.payload.getString("originalSport")==w.sport)
        } }.map { w -> Entry("workout:${w.id}",JSONObject().put("originalStart",w.start).put("originalSport",w.sport)
            .put("start",w.start).put("end",w.end).put("sport",w.sport).put("energyKcal",w.energyKcal ?: JSONObject.NULL)
            .put("distanceM",w.distanceM ?: JSONObject.NULL).put("steps",w.steps ?: JSONObject.NULL),
            w.userModified || w.source.lowercase().contains("manual"),w.source) }
        val visible=journal+legacy
        val selected=mutableListOf<JSONObject>(); val occupied=mutableListOf<SleepBounds>(); val gaps=linkedSetOf<String>()
        if(ownsDay && future.isNotEmpty()) gaps+="manual_workout_ends_after_asof_cutoff"
        var strength=0.0
        for(edit in visible) {
            val p=edit.payload; val start=p.getLong("start"); val end=p.getLong("end"); val bounds=SleepBounds(start,end)
            if(occupied.any { it.start<end && start<it.end }) { gaps+="overlapping_workouts_explicit_journal_then_latest_upload_wins"; continue }
            occupied+=bounds
            val hr=input.hr.filter { it.ts in start until end && it.bpm in 20..250 }
            val maxHR=if(config.isNull("maxHR")) StrainScorer.estimateHRmax(hr.map { it.bpm.toDouble() },input.profile.age).first else config.getDouble("maxHR")
            val rhr=result.daily.restingHr?.toDouble() ?: StrainScorer.defaultRestingHR
            val zoneSet=ScoringPreferences.displayZones(input.profile.age,config); val zones=hr.takeIf { it.isNotEmpty() }?.let { HrZones.timeInZone(it,zoneSet) }
            val energy=if(!p.isNull("energyKcal")) p.getDouble("energyKcal") else
                hr.takeIf { it.isNotEmpty() }?.let { Calories.estimateBoutCalories(it,input.profile,maxHR,rhr).first }
            if(hr.isEmpty()) gaps+=if(edit.legacySource==null) "manual_workout_raw_physiology_unavailable" else "uploaded_workout_raw_physiology_unavailable"
            val sport=p.getString("sport").lowercase()
            // Existing WhoopImporter activity-name predicate, including free-typed labels.
            if(sport.contains("strength") || sport.contains("weight")) strength+=(end-start)/60.0
            selected+=JSONObject().put("id",edit.entity.removePrefix("workout:")).put("editEntity",edit.entity)
                .put("originalStart",p.getLong("originalStart")).put("originalSport",p.getString("originalSport"))
                .put("start",start).put("end",end).put("sport",p.getString("sport")).put("manual",edit.manual)
                .put("inputKind",if(edit.legacySource==null) "manual_workout_journal" else "legacy_uploaded_workout")
                .put("inputSource",edit.legacySource ?: "user_entered")
                .put("durationS",end-start).put("avgHr",hr.takeIf { it.isNotEmpty() }?.map { it.bpm }?.average() ?: JSONObject.NULL)
                .put("peakHr",hr.maxOfOrNull { it.bpm } ?: JSONObject.NULL)
                .put("strain",StrainScorer.strain(hr,maxHR,rhr,method,input.profile.sex) ?: JSONObject.NULL)
                .put("energyKcal",energy ?: JSONObject.NULL).put("energyMethod",if(p.isNull("energyKcal")) "hr_estimate" else edit.legacySource?.let { "imported:$it" } ?: "user_entered")
                .put("distanceM",p.opt("distanceM") ?: JSONObject.NULL).put("steps",p.opt("steps") ?: JSONObject.NULL)
                .put("hrCoveragePct",hr.takeIf { it.isNotEmpty() }?.let { WorkoutDetector.hrCoveragePct(it.map { s -> s.ts },start,end) } ?: JSONObject.NULL)
                .put("zoneSeconds",zones?.let { JSONArray(it.seconds) } ?: JSONObject.NULL).put("zoneMethod","hrmax_display_zones")
        }
        for(w in result.workouts) {
            // An anchored edit replaces/suppresses its original event, including a move to another day.
            if(manual.any { val p=it.payload; p.getLong("originalStart")==w.start } ||
                occupied.any { it.start<w.end && w.start<it.end }) continue
            val id=UUID.nameUUIDFromBytes("workout-v1|${input.userId}|${input.deviceId}|${w.start}".toByteArray(StandardCharsets.UTF_8))
            selected+=JSONObject().put("id",id).put("start",w.start).put("end",w.end).put("manual",false).put("sport","Activity")
                .put("durationS",w.durationS).put("avgHr",w.avgHR).put("peakHr",w.peakHR)
                .put("strain",w.strain ?: JSONObject.NULL).put("energyKcal",w.caloriesKcal ?: JSONObject.NULL)
                .put("energyKJ",w.caloriesKJ ?: JSONObject.NULL).put("energyMethod","hr_estimate")
                .put("zoneTimePct",JSONObject(w.zoneTimePct.mapKeys { it.key.toString() })).put("zoneMethod","edwards_hrr_samples")
                .put("avgHrrPct",w.avgHRRPct ?: JSONObject.NULL).put("hrmax",w.hrmax ?: JSONObject.NULL)
                .put("hrmaxSource",w.hrmaxSource).put("hrCoveragePct",w.hrCoveragePct ?: JSONObject.NULL)
        }
        val displayZones=ScoringPreferences.displayZones(input.profile.age,config)
        for(w in selected) {
            val start=w.getLong("start");val end=w.getLong("end")
            // WorkoutDetailView uses its inclusive session window, not the daily counter predecessor.
            val onFoot=w.getString("sport").trim().lowercase() in setOf("running","walking","hiking","treadmill run","treadmill walk")
            val ticks=if(onFoot) StepsCounter.stepsInWindow(input.steps.filter { it.ts in start..minOf(end,input.dayHi) }) else null
            val scale=maxOf(input.profile.stepTicksPerStep,0.5)
            val strapSteps=ticks?.let { kotlin.math.floor(it/scale+0.5).toInt().takeIf { count -> count>0 } }
            w.put("strapSteps",strapSteps ?: JSONObject.NULL).put("stepCounterTicks",ticks ?: JSONObject.NULL)
                .put("strapStepsMethod","session_inclusive_activity_class_counter")
                .put("stepTicksPerStep",if(onFoot) scale else JSONObject.NULL)
            val hr=input.hr.filter { it.ts in start until end && it.bpm in 20..250 }
            val recovery=HeartRateRecovery.calculate(input.hr.filter { it.ts<=input.dayHi },start,end,displayZones.maxHR)
            w.put("heartRateRecovery",recovery?.let { r -> JSONObject().put("endHr",r.endHr)
                .put("after1Minute",r.after1Minute ?: JSONObject.NULL).put("after2Minutes",r.after2Minutes ?: JSONObject.NULL)
                .put("after5Minutes",r.after5Minutes ?: JSONObject.NULL).put("unit","bpm_drop") } ?: JSONObject.NULL)
            w.put("hrBuckets",JSONArray(hr.groupBy { start+Math.floorDiv(it.ts-start,60)*60 }.toSortedMap().map { (ts,rows) ->
                JSONObject().put("start",ts).put("end",minOf(end,ts+60)).put("value",rows.map { it.bpm }.average())
                    .put("min",rows.minOf { it.bpm }).put("max",rows.maxOf { it.bpm }).put("count",rows.size)
            }))
            w.put("displayZoneSeconds",hr.takeIf { it.isNotEmpty() }?.let { JSONArray(HrZones.timeInZone(it,displayZones).seconds) } ?: JSONObject.NULL)
                .put("displayZoneSource",displayZones.source).put("displayZoneLowerBounds",JSONArray(displayZones.zones.map { it.lower }))
        }
        val known=ownsDay && (input.hr.any { it.ts in lo until hi } || visible.isNotEmpty())
        return Result(JSONArray(selected.sortedWith(compareBy({it.getLong("start")},{it.getString("id")}))),
            if(known) selected.size else null,if(visible.isNotEmpty()) strength else null,gaps)
    }
}
