package com.frwhoop.scoring.db

import com.frwhoop.scoring.scoring.ServerScoreBundle
import com.frwhoop.scoring.scoring.SleepBounds
import com.frwhoop.scoring.scoring.SleepIdentity
import com.noop.analytics.DetectedSleep
import com.noop.analytics.SleepStageTotals
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

/** Publishes only through the atomic queue-token/input-generation database fence. */
class EngineIngestWriter(private val queue: ScoringWorkQueue) {
    fun write(item: ScoringWorkQueue.WorkItem, bundle: ServerScoreBundle, durationMs: Long): Long? {
        require(item.userId == bundle.userId && item.deviceId.toString() == bundle.deviceId &&
            item.day == bundle.day && item.algorithmVersion == bundle.algorithmVersion)
        val payload=buildSnapshot(bundle)
        return if(item.historyGeneration == null) {
            require(bundle.historyCommit == null)
            queue.publish(item,payload,durationMs)
        } else {
            val history=requireNotNull(bundle.historyCommit)
            payload.put("dependency",JSONObject().put("stateSchemaVersion",1).put("generation",item.historyGeneration)
                .put("predecessorResultRevision",item.predecessorRevision ?: JSONObject.NULL)
                .put("profileRevision",history.profileRevision).put("configurationRevision",history.configurationRevision)
                .put("sourceEra",history.prepared.sourceEra))
            queue.publishHistory(item,payload,history.state,history.profileRevision,history.configurationRevision,durationMs)
        }
    }

    companion object {
        fun buildSnapshot(bundle: ServerScoreBundle): JSONObject {
            val legacy = buildPayload(bundle)
            val noData = bundle.dataThrough == null && bundle.result.sleepSessions.isEmpty() && !bundle.hasNonRawObservations
            return JSONObject()
                .put("timezone", bundle.timezone)
                .put("dataThrough", bundle.dataThrough?.let { Instant.ofEpochSecond(it).toString() } ?: JSONObject.NULL)
                .put("status", if (noData) "no_data" else "partial")
                .put("capabilities",JSONArray(listOf("hrv_rmssd_ms","hrv_sdnn_ms","resting_hr_bpm","resp_rate_bpm",
                    "sleep_total_min","sleep_in_bed_min","sleep_awake_min","sleep_light_min","sleep_deep_min",
                    "sleep_rem_min","sleep_efficiency","disturbances","sleep_sessions")+(bundle.derived?.capabilities?.sorted() ?: emptyList())))
                .put("coverage", JSONObject()
                    .put("hrSamples",bundle.hrSamples).put("rrIntervals",bundle.rrIntervals)
                    .put("gaps",JSONArray(bundle.coverageGaps))
                    .put("historicalStateAvailable",bundle.historyCommit != null))
                .put("daily",if (noData) JSONObject.NULL else legacy.getJSONArray("daily_metrics").getJSONObject(0))
                .put("sleep",legacy.getJSONArray("sleep_nights"))
                .also { payload -> bundle.derived?.let {
                    payload.put("metrics",it.metrics).put("details",it.details).put("charts",it.charts)
                        .put("chartMetadata",it.chartMetadata).put("history",it.history)
                } }
        }

        /** Legacy field spelling remains the nested v2 wire vocabulary. */
        fun buildPayload(bundle: ServerScoreBundle): JSONObject {
            val daily = bundle.result.daily
            val sessions = bundle.result.sleepSessions
            val candidates = sessions.withIndex().filter { bundle.sleepNapOverrides[SleepBounds(it.value.start,it.value.end)] != true }
            val group = SleepStageTotals.mainNightGroupIndices(
                candidates.map { SleepStageTotals.NightBlock(it.value.start,it.value.end) }, bundle.tzOffsetSeconds,
                bundle.historyCommit?.prepared?.habitualMidsleep,
                java.time.ZoneId.of(bundle.timezone),
            )?.map { candidates[it].index }?.toSet() ?: emptySet()
            val main = sessions.filterIndexed { index,_ -> index in group }
            val start = main.minOfOrNull { it.start }
            val end = main.maxOfOrNull { it.end }
            val inBed = if (start != null && end != null) (end-start)/60.0 else null
            val asleep = daily.totalSleepMin
            val d = JSONObject()
                .put("day",bundle.day).put("source_device_id",bundle.deviceId)
                .value("hrv_rmssd_ms",daily.avgHrv).value("hrv_sdnn_ms",daily.avgSdnn)
                .value("resting_hr_bpm",daily.restingHr).value("resp_rate_bpm",daily.respRateBpm)
                .value("sleep_total_min",daily.totalSleepMin).value("sleep_in_bed_min",inBed)
                .value("sleep_awake_min",if (asleep != null && main.any { it.stages.isNotEmpty() })
                    main.flatMap { it.stages }.filter { it.stage=="wake" }.sumOf { it.end-it.start }/60.0 else null)
                .value("sleep_light_min",daily.lightMin).value("sleep_deep_min",daily.deepMin)
                .value("sleep_rem_min",daily.remMin).value("sleep_efficiency",daily.efficiency)
                .value("sleep_onset_at",start?.let { Instant.ofEpochSecond(it).toString() })
                .value("wake_onset_at",end?.let { Instant.ofEpochSecond(it).toString() })
                .value("overnight_hr_bpm",main.mapNotNull { it.restingHR }.minOrNull())
                .value("disturbances",daily.disturbances)
                .also { if(bundle.derived != null) it.value("recovery",daily.recovery).value("strain",daily.strain)
                .value("exercise_count",daily.exerciseCount).value("steps",daily.steps)
                .value("active_kcal_est",daily.activeKcalEst).value("spo2_pct",daily.spo2Pct)
                .value("spo2_red",daily.spo2Red).value("spo2_ir",daily.spo2Ir)
                .value("skin_temp_c",daily.skinTempC).value("skin_temp_dev_c",daily.skinTempDevC)
                .value("sleep_hr_only",daily.sleepHrOnly) }
            val nights = JSONArray()
            sessions.forEachIndexed { index,s -> nights.put(sessionToJson(s,bundle,
                bundle.sleepNapOverrides[SleepBounds(s.start,s.end)] ?: (index !in group))) }
            return JSONObject().put("user_id",bundle.userId.toString()).put("algorithm_version",bundle.algorithmVersion)
                .put("daily_metrics",JSONArray().put(d)).put("sleep_nights",nights)
        }

        private fun sessionToJson(s: DetectedSleep,b: ServerScoreBundle,nap: Boolean): JSONObject {
            val stages = JSONArray()
            s.stages.forEach { stages.put(JSONObject().put("start",it.start).put("end",it.end).put("stage",it.stage)) }
            fun minutes(stage: String) = s.stages.filter { it.stage==stage }.sumOf { (it.end-it.start).coerceAtLeast(0) }/60.0
            val inBed = (s.end-s.start)/60.0
            val hasStages = s.stages.isNotEmpty()
            val asleep = if (hasStages) minutes("light")+minutes("deep")+minutes("rem") else null
            val identity = b.sleepIdentities[SleepBounds(s.start, s.end)]
                ?: SleepIdentity.detected(b.userId, b.deviceId, s.start, s.end)
            return JSONObject().put("id",identity.id).put("period_day",b.day).put("device_id",b.deviceId)
                .put("originalStart",identity.originalStart).put("originalEnd",identity.originalEnd)
                .put("editEntity",identity.editEntity)
                .put("start_at",Instant.ofEpochSecond(s.start).toString()).put("end_at",Instant.ofEpochSecond(s.end).toString())
                .put("is_nap",nap).put("in_bed_min",inBed).value("asleep_min",asleep)
                .value("awake_min",if (hasStages) minutes("wake") else null)
                .value("light_min",if (hasStages) minutes("light") else null)
                .value("deep_min",if (hasStages) minutes("deep") else null)
                .value("rem_min",if (hasStages) minutes("rem") else null)
                .value("efficiency",if (hasStages) s.efficiency else null).value("resting_hr_bpm",s.restingHR).value("hrv_rmssd_ms",s.avgHRV)
                .put("stages",stages)
        }

        private fun JSONObject.value(key: String,value: Any?): JSONObject = put(key,value ?: JSONObject.NULL)
    }
}
