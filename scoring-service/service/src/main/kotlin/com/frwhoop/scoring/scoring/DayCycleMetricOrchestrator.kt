package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.*
import org.json.JSONObject
import java.time.ZoneId
import kotlin.math.roundToLong

/** Existing additive engines on a single source-local cycle, observed only through this day. */
object DayCycleMetricOrchestrator {
    data class Result(val scored:DayResult,val window:DayCycleWindow,val mode:DayCycleMode,
                      val appliesToDay:Boolean,val stepCount:SleepAwareStepCounter.Count? = null,
                      val gaps:Set<String> = emptySet()) {
        val usesCalendar get()=window.source==DayCycleWindow.Source.CALENDAR
        fun details(day:String)=JSONObject().put("mode",mode.persistedValue).put("id",window.id)
            .put("startInclusive",window.startInclusive).put("endExclusive",window.endExclusive)
            .put("displayDay",window.displayDay).put("source",window.source.name.lowercase())
            .put("asOfDay",day).put("openAsOfCutoff",!usesCalendar).put("appliesToDay",appliesToDay)
            .put("counter",stepCount?.let { JSONObject().put("totalTicks",it.totalTicks)
                .put("acceptedOutsideSleepTicks",it.acceptedOutsideSleepTicks).put("acceptedAwakeGapTicks",it.acceptedAwakeGapTicks)
                .put("acceptedSleepBoutTicks",it.acceptedSleepBoutTicks).put("rejectedIsolatedSleepTicks",it.rejectedIsolatedSleepTicks)
                .put("rejectedActivityClassTicks",it.rejectedActivityClassTicks).put("rejectedImplausibleTicks",it.rejectedImplausibleTicks)
            } ?: JSONObject.NULL)
    }

    fun evaluate(input:SignalSampleReader.DayInputs,result:DayResult,p:HistoricalStateMachine.Prepared,
                 identities:Map<SleepBounds,SleepIdentity> = emptyMap(),naps:Map<SleepBounds,Boolean> = emptyMap()):Result {
        val mode=DayCycleMode.fromPersisted(input.history.configuration.optString("dayCycleMode","sleep_onset"))
        val end=input.dayHi+1
        val calendar=DayCycleWindow("calendar:${input.day}",input.dayLo,end,input.day,DayCycleWindow.Source.CALENDAR)
        if(mode==DayCycleMode.MIDNIGHT) return Result(result,calendar,mode,true)
        val zone=ZoneId.of(input.timezone)
        val blocks=result.sleepSessions.filter { it.start<it.end && it.end<=end }.map { s ->
            val bounds=SleepBounds(s.start,s.end)
            val identity=identities[bounds] ?: SleepIdentity.detected(input.userId,input.deviceId,s.start,s.end)
            PhysiologicalSteps.SleepBlock(s.start,s.end,identity.id.toString(),
                kind=if(naps[bounds]==true) PhysiologicalSteps.SleepKind.NAP else PhysiologicalSteps.SleepKind.UNCLASSIFIED)
        }
        val winner=PhysiologicalSteps.classifyForCycle(blocks,input.tzOffsetSeconds,p.habitualMidsleep,zone)
            .filter { it.kind==PhysiologicalSteps.SleepKind.MAIN_SLEEP }.minByOrNull { it.effectiveOnset }
        val current=winner?.let { DayCycleWindow(it.id,it.effectiveOnset,end,input.day,
            if(identities.keys.any { b -> b.start==it.effectiveOnset }) DayCycleWindow.Source.EDITED_SLEEP else DayCycleWindow.Source.DETECTED_SLEEP) }
        val previous=p.history.lastOrNull()?.optJSONObject("dayCycle")?.takeUnless { it.optString("source")=="calendar" }?.let {
            DayCycleWindow(it.getString("id"),it.getLong("startInclusive"),end,it.getString("displayDay"),
                DayCycleWindow.Source.valueOf(it.getString("source").uppercase()))
        }
        val latest=listOfNotNull(previous,current).maxByOrNull { it.startInclusive }
            ?: return Result(result,calendar,mode,true)
        val window=DayCycleResolver.activeWindow(mode,latest,end,input.tzOffsetSeconds,zone)
        val applies=window.displayDay==input.day
        if(!applies || window.startInclusive<input.nightLo) {
            val gap=if(applies) "day_cycle_raw_window_unavailable" else "additive_cycle_owned_by_other_day"
            return Result(result.copy(daily=result.daily.copy(strain=null,steps=null,activeKcalEst=null,exerciseCount=null),
                strain=null,workouts=emptyList(),effortConfidence=ScoreConfidence.CALIBRATING),window,mode,applies,gaps=setOf(gap))
        }
        val start=window.startInclusive
        val hr=input.hr.filter { it.ts in start until end }
        val gravity=input.gravity.filter { it.ts in start until end }
        val config=input.history.configuration
        val maxHR=if(config.isNull("maxHR")) input.profile.age.takeIf { it>0 }?.let(StrainScorer::tanakaHRmax) else config.getDouble("maxHR")
        val rhr=result.daily.restingHr?.toDouble() ?: StrainScorer.defaultRestingHR
        val method=StrainScorer.Method.valueOf(p.effortMethod)
        val strain=StrainScorer.strain(hr,maxHR,rhr,method,input.profile.sex)
        val energy=hr.takeIf { it.isNotEmpty() }?.let { Calories.estimateDayCalories(it,input.profile,maxHR,rhr) }
        val stepRows=input.steps.filter { it.ts in start until end }
        val predecessor=input.steps.filter { it.ts<start }.maxByOrNull { it.ts }
        val counterRows=listOfNotNull(predecessor)+stepRows
        val counts=if(counterRows.size>=2) SleepAwareStepCounter.Accumulator(result.sleepSessions,StepsCounter.hasActivityClasses(stepRows))
            .observeMotionPage(gravity,input.v18Aux.filter { it.ts in start until end }).acceptPage(counterRows).finish() else null
        val steps=counts?.let { (it.totalTicks/maxOf(input.profile.stepTicksPerStep,0.5)).roundToLong()
            .coerceAtMost(Int.MAX_VALUE.toLong()).toInt() }
        var funnel:WorkoutDetector.DetectionFunnel?=null
        val workouts=WorkoutDetector.detect(hr,gravity,result.daily.restingHr?.toDouble(),maxHR,
            input.profile.age.takeIf { it>0 },input.profile,method) { funnel=it }
        val scored=result.copy(daily=result.daily.copy(strain=strain,steps=steps,activeKcalEst=energy,
            exerciseCount=workouts.size.takeIf { hr.isNotEmpty() }),strain=strain,workouts=workouts,
            detectionFunnel=funnel,effortConfidence=ScoreConfidence.forEffort(strain,hr.size))
        return Result(scored,window,mode,true,counts)
    }
}
