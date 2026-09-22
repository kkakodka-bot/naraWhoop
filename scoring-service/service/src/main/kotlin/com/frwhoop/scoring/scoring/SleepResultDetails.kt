package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.DayResult
import com.noop.analytics.SleepStager
import org.json.JSONArray
import org.json.JSONObject

/** Complete existing session diagnostics, keyed by the same immutable edit identity as `sleep`. */
internal object SleepResultDetails {
    fun build(input: SignalSampleReader.DayInputs, result: DayResult, prepared: HistoricalStateMachine.Prepared,
              identities: Map<SleepBounds, SleepIdentity>, naps: Map<SleepBounds, Boolean>): JSONArray {
        val main = HistoricalObservationWindows.mainNightIndices(input,result,prepared.habitualMidsleep,naps)
        return JSONArray(result.sleepSessions.mapIndexed { index, s ->
            val identity=identities[SleepBounds(s.start,s.end)] ?: SleepIdentity.detected(input.userId,input.deviceId,s.start,s.end)
            val metrics=s.stages.takeIf { it.isNotEmpty() }?.let { SleepStager.hypnogramMetrics(s) }
            fun finite(value:Double?):Any=value?.takeIf { it.isFinite() } ?: JSONObject.NULL
            val motion=result.sessionMotionByStart[s.start]
            val counts=input.gravity.filter { it.ts in s.start until s.end }.groupingBy { ((it.ts-s.start)/30).toInt() }.eachCount()
            JSONObject().put("id",identity.id).put("editEntity",identity.editEntity).put("start",s.start).put("end",s.end)
                .put("isNap",naps[SleepBounds(s.start,s.end)] ?: (index !in main)).put("hrOnly",s.hrOnly)
                .put("stagingSparse",result.gravitySparse).put("stagedSeconds",s.stages.sumOf { it.end-it.start })
                .put("stageCoverage",s.stages.takeIf { it.isNotEmpty() }?.sumOf { it.end-it.start }?.toDouble()?.div(s.end-s.start) ?: JSONObject.NULL)
                .put("hypnogram",metrics?.let { m -> JSONObject().put("inBedS",m.tibS).put("asleepS",m.tstS)
                    .put("sleepPeriodS",m.sptS).put("sleepLatencyS",m.solS).put("remLatencyS",finite(m.remLatencyS))
                    .put("wakeAfterSleepOnsetS",m.wasoS).put("disturbances",m.disturbances) } ?: JSONObject.NULL)
                .put("motion",motion?.let { values -> JSONObject().put("start",s.start).put("epochSeconds",30)
                    .put("unit","gravity_delta_sum").put("method","existing_stager_epoch_motion_observed_mask")
                    .put("values",JSONArray(values.mapIndexed { i,v -> if((counts[i] ?: 0)>0) finite(v) else JSONObject.NULL }))
                    .put("counts",JSONArray(values.indices.map { counts[it] ?: 0 })) } ?: JSONObject.NULL)
                .put("bandState",result.sessionSleepStateByStart[s.start]?.let { values ->
                    JSONObject().put("start",s.start).put("epochSeconds",30).put("values",JSONArray(values))
                        .put("method","raw_band_code_last_observation_carried_forward").put("isDerivedStage",false)
                } ?: JSONObject.NULL)
                .put("stageInsights",JSONArray(listOf("wake","light","deep","rem").map { stage ->
                    val spans=s.stages.filter { it.stage==stage }
                    val hr=input.hr.filter { it.bpm>0 && spans.any { span -> it.ts in span.start until span.end } }
                    JSONObject().put("stage",stage).put("durationS",if(s.stages.isNotEmpty()) spans.sumOf { it.end-it.start } else JSONObject.NULL)
                        .put("hrSampleCount",hr.size).put("meanHr",if(hr.isEmpty()) JSONObject.NULL else hr.map { it.bpm }.average())
                }))
        })
    }
}
