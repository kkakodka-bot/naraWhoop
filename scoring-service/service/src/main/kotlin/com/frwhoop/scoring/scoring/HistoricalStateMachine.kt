package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.HistoryCheckpointReader
import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.*
import com.noop.data.DailyMetric
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import kotlin.math.ln

/** State before D is built only from immutable observations dated strictly before D. */
object HistoricalStateMachine {
    data class Prepared(
        val day: String,
        val history: List<JSONObject>,
        val baselines: Map<String, BaselineState>,
        val sourceEra: String,
        val hrvEpoch: Double,
        val recoveryEpoch: Double,
        val effortMethod: String,
        val needHours: Double,
        val consistency: Double?,
        val habitualMidsleep: Long?,
        val skinTempAnchorRaw: Double? = null,
    ) {
        val profileBaselines get() = ProfileBaselines(baselines["hrv"]?.takeIf { it.usable },baselines["resting_hr"]?.takeIf { it.usable },
            baselines["resp"]?.takeIf { it.usable },baselines["skin_temp"]?.takeIf { it.usable })
        val baselineEpochSeconds get() = Baselines.metricCfg.keys.associateWith {
            baselineEpoch(it,hrvEpoch,recoveryEpoch)
        }
    }

    data class Commit(val state: JSONObject, val profileRevision: Long, val configurationRevision: Long,
                      val sleepDebt: SleepDebtLedger, val prepared: Prepared)

    fun prepare(inputs: SignalSampleReader.DayInputs, seed: HistoryCheckpointReader.Seed): Prepared {
        val day = LocalDate.parse(inputs.day)
        val history = seed.history
        require(history.all { it.getString("day") < inputs.day }) { "future_history_observation" }
        require(history.map { it.getString("day") }.zipWithNext().all { (a,b) -> a < b }) { "unordered_history_observation" }
        require(seed.predecessor == null || seed.predecessor.getString("throughDay") < inputs.day)
        val config = inputs.history.configuration
        val era = config.optString("sourceEra",inputs.deviceId)
        val hrvEpoch = config.number("hrvBaselineEpoch") ?: 0.0
        val recoveryEpoch = config.number("recoveryBaselineEpoch") ?: 0.0
        val method = config.optString("effortMethod","EDWARDS")
        val eligible = history.filter { it.getString("sourceEra") == era }
        val previous = seed.predecessor
        val samePolicy = previous != null && previous.getString("sourceEra")==era &&
            previous.getDouble("hrvEpoch")==hrvEpoch && previous.getDouble("recoveryEpoch")==recoveryEpoch &&
            previous.getString("effortMethod")==method
        val rawBaselines = if (samePolicy) {
            decodeBaselines(previous!!.getJSONObject("baselinesAfter")).mapValues { (key,value) ->
                var state = value
                var missingDay = LocalDate.parse(previous.getString("throughDay")).plusDays(1)
                while (missingDay < day) {
                    if (baselineDayIsEligible(missingDay,key,hrvEpoch,recoveryEpoch)) {
                        state = Baselines.update(state,null,Baselines.metricCfg.getValue(key),key!="readiness_hrv_ln")
                    }
                    missingDay = missingDay.plusDays(1)
                }
                state
            }
        } else {
            val byDay = eligible.associateBy { it.getString("day") }
            Baselines.metricCfg.mapValues { (key,cfg) ->
                var state: BaselineState? = null
                var cursor = eligible.firstOrNull()?.getString("day")?.let(LocalDate::parse) ?: day
                while (cursor < day) {
                    // Same epoch-day rule as Baselines.foldHistory, independent of today's timezone.
                    if (baselineDayIsEligible(cursor,key,hrvEpoch,recoveryEpoch)) {
                        val row = byDay[cursor.toString()]
                        val value = if (key=="strain" && row?.optString("effortMethod")!=method) null
                            else row?.optJSONObject("baselineObservations")?.number(key)
                        state = Baselines.update(state,value,cfg,key!="readiness_hrv_ln")
                    }
                    cursor = cursor.plusDays(1)
                }
                state ?: Baselines.foldHistory(emptyList(),cfg)
            }
        }
        // A newly learned ADC offset must also change the scale of the earlier thermal inputs,
        // not create a false deviation by comparing two different calibrations.
        val baselines=if(inputs.deviceFamily==com.noop.protocol.DeviceFamily.WHOOP4)
            rawBaselines+("skin_temp" to HistoricalThermalState.baseline(eligible,inputs.day,recoveryEpoch,inputs.skinTempAnchorRaw))
            else rawBaselines
        // The existing learner selects the longest block per local midpoint day, using asleep time
        // for need/regularity. No guessed 90% efficiency when an edit has no raw stage evidence.
        val blocks = eligible.flatMap { row ->
            val zone = ZoneId.of(row.getString("timezone"))
            row.getJSONArray("sleepBlocks").objects().mapNotNull { b ->
                val start=b.getLong("start"); val end=b.getLong("end")
                val asleep=b.number("asleepMin") ?: return@mapNotNull null
                val midpoint=Instant.ofEpochSecond(start+(end-start)/2)
                val offset=zone.rules.getOffset(midpoint).totalSeconds.toLong()
                Triple(SleepStageTotals.HistoryBlock(start+offset,end+offset,midpoint.atZone(zone).toLocalDate().toString()),asleep,start)
            }
        }.distinctBy { it.third }
        val longest = blocks.groupBy { it.first.dayKey }.toSortedMap().values.map { candidates ->
            candidates.sortedWith(compareByDescending<Triple<SleepStageTotals.HistoryBlock,Double,Long>> { it.first.durationS }.thenBy { it.third }).first()
        }
        val hours = longest.map { it.second/60.0 }
        val need = config.number("sleepNeedHours") ?: RestScorer.personalizedNeedHours(hours,inputs.profile.age.toInt())
        return Prepared(inputs.day,eligible,baselines,era,hrvEpoch,recoveryEpoch,method,need,
            VitalityEngine.sleepConsistency(hours.takeLast(28)),SleepStageTotals.habitualMidsleepSec(blocks.map { it.first },0),inputs.skinTempAnchorRaw)
    }

    fun finish(inputs: SignalSampleReader.DayInputs, result: DayResult, prepared: Prepared,
               napOverrides: Map<SleepBounds,Boolean>, extraBaselines: Map<String,Double?> = emptyMap()): Commit {
        require(inputs.day==prepared.day)
        val d = result.daily
        val observations = linkedMapOf("hrv" to d.avgHrv,"resting_hr" to d.restingHr?.toDouble(),
            "resp" to d.respRateBpm,"skin_temp" to result.nightlySkinTempC,"strain" to d.strain,
            "readiness_hrv_ln" to d.avgHrv?.takeIf { it>0 }?.let(::ln)) + extraBaselines
        val after = Baselines.metricCfg.mapValues { (key,cfg) ->
            if(!baselineDayIsEligible(LocalDate.parse(inputs.day),key,prepared.hrvEpoch,prepared.recoveryEpoch))
                prepared.baselines.getValue(key)
            else Baselines.update(prepared.baselines[key],observations[key],cfg,key!="readiness_hrv_ln")
        }
        val group=HistoricalObservationWindows.mainNightIndices(inputs,result,prepared.habitualMidsleep,napOverrides)
        val mainNight=HistoricalObservationWindows.mainNight(inputs,result,prepared.habitualMidsleep,napOverrides)
        fun asleep(s: DetectedSleep): Double? = if(s.stages.isEmpty()) null else
            s.stages.filter { it.stage in setOf("light","deep","rem") }.sumOf { it.end-it.start }/60.0
        val naps=result.sleepSessions.filterIndexed { index,_ -> index !in group }.mapNotNull(::asleep).sum()
        val credited=SleepDebt.creditedSleepMin(d.totalSleepMin,naps)
        val observation=JSONObject().put("day",inputs.day).put("timezone",inputs.timezone)
            .put("sourceEra",prepared.sourceEra).put("effortMethod",prepared.effortMethod)
            .put("baselineEpochSeconds",JSONObject(prepared.baselineEpochSeconds))
            .put("daily",DailyMetricJson.encode(d)).put("baselinesBefore",encodeBaselines(prepared.baselines))
            .put("baselineObservations",JSONObject(observations.mapValues { it.value ?: JSONObject.NULL }))
            .put("creditedSleepMin",credited ?: JSONObject.NULL)
            .put("mainNightBounds",mainNight?.let { JSONObject().put("start",it.start).put("end",it.end) } ?: JSONObject.NULL)
            .put("sleepBlocks",JSONArray(result.sleepSessions.map { s -> JSONObject().put("start",s.start).put("end",s.end)
                .put("asleepMin",asleep(s) ?: JSONObject.NULL) }))
        observation.put("hourlyHrSchemaVersion",2)
        observation.put("hourlyHr",JSONArray(HistoricalObservationWindows.hourlyHr(inputs).map {
            JSONObject().put("start",it.start).put("meanHr",it.meanHr).put("sampleCount",it.sampleCount)
        }))
        observation.put("dayMotion",StepsEstimateEngine.dayMotionIntensity(inputs.gravity.filter { it.ts in inputs.dayLo..inputs.dayHi }))
        if(inputs.deviceFamily==com.noop.protocol.DeviceFamily.WHOOP4) {
            observation.put("whoop4WornNightRawCounts",HistoricalThermalState.observedRawHistogram(inputs,result))
                .put("skinTempAnchorRaw",inputs.skinTempAnchorRaw ?: JSONObject.NULL)
        }
        val debt=SleepDebt.ledger(prepared.history.map { it.getString("day") to it.number("creditedSleepMin") } +
            (inputs.day to credited),prepared.needHours)
        val state=JSONObject().put("schemaVersion",1).put("throughDay",inputs.day).put("sourceEra",prepared.sourceEra)
            .put("hrvEpoch",prepared.hrvEpoch).put("recoveryEpoch",prepared.recoveryEpoch).put("effortMethod",prepared.effortMethod)
            .put("baselinesAfter",encodeBaselines(after)).put("observation",observation)
            .put("sleepNeedHours",prepared.needHours).put("sleepDebtBalanceMin",debt.balanceMin)
        return Commit(state,inputs.history.profile?.revision ?: 0,inputs.history.config?.revision ?: 0,debt,prepared)
    }

    private fun baselineEpoch(key: String, hrvEpoch: Double, recoveryEpoch: Double) =
        if(key=="hrv" || key=="readiness_hrv_ln") hrvEpoch else recoveryEpoch

    /** Missing days and observations use the same per-metric UTC epoch-day admission rule. */
    private fun baselineDayIsEligible(day: LocalDate, key: String, hrvEpoch: Double, recoveryEpoch: Double) =
        day.atStartOfDay(ZoneOffset.UTC).toEpochSecond() >= baselineEpoch(key,hrvEpoch,recoveryEpoch)

    fun encodeBaselines(states: Map<String,BaselineState>) = JSONObject(states.mapValues { (_,s) -> JSONObject()
        .put("baseline",s.baseline).put("spread",s.spread).put("nValid",s.nValid)
        .put("nightsSinceUpdate",s.nightsSinceUpdate).put("status",s.status.raw) })
    fun decodeBaselines(json: JSONObject): Map<String,BaselineState> = json.keySet().associateWith { key ->
        val s=json.getJSONObject(key)
        BaselineState(s.getDouble("baseline"),s.getDouble("spread"),s.getInt("nValid"),s.getInt("nightsSinceUpdate"),
            BaselineStatus.entries.single { it.raw==s.getString("status") })
    }
    internal fun JSONObject.number(key: String): Double? = if(isNull(key)) null else getDouble(key)
    internal fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
}

/** Explicit checkpoint codec: no reflection, Room dependency, or lossy daily-field subset. */
object DailyMetricJson {
    fun encode(d: DailyMetric) = JSONObject(linkedMapOf(
        "deviceId" to d.deviceId,"day" to d.day,"totalSleepMin" to d.totalSleepMin,"efficiency" to d.efficiency,
        "deepMin" to d.deepMin,"remMin" to d.remMin,"lightMin" to d.lightMin,"disturbances" to d.disturbances,
        "restingHr" to d.restingHr,"avgHrv" to d.avgHrv,"recovery" to d.recovery,"strain" to d.strain,
        "exerciseCount" to d.exerciseCount,"spo2Pct" to d.spo2Pct,"skinTempDevC" to d.skinTempDevC,
        "respRateBpm" to d.respRateBpm,"steps" to d.steps,"activeKcalEst" to d.activeKcalEst,
        "spo2Red" to d.spo2Red,"spo2Ir" to d.spo2Ir,"avgSdnn" to d.avgSdnn,"skinTempC" to d.skinTempC,
        "sleepHrOnly" to d.sleepHrOnly).mapValues { it.value ?: JSONObject.NULL })
    fun decode(j: JSONObject): DailyMetric {
        fun n(key:String)=if(j.isNull(key)) null else j.getDouble(key)
        return DailyMetric(deviceId=j.getString("deviceId"),day=j.getString("day"),totalSleepMin=n("totalSleepMin"),
            efficiency=n("efficiency"),deepMin=n("deepMin"),remMin=n("remMin"),lightMin=n("lightMin"),
            disturbances=n("disturbances")?.toInt(),restingHr=n("restingHr")?.toInt(),avgHrv=n("avgHrv"),
            recovery=n("recovery"),strain=n("strain"),exerciseCount=n("exerciseCount")?.toInt(),spo2Pct=n("spo2Pct"),
            skinTempDevC=n("skinTempDevC"),respRateBpm=n("respRateBpm"),steps=n("steps")?.toInt(),activeKcalEst=n("activeKcalEst"),
            spo2Red=n("spo2Red")?.toInt(),spo2Ir=n("spo2Ir")?.toInt(),avgSdnn=n("avgSdnn"),skinTempC=n("skinTempC"),
            sleepHrOnly=if(j.isNull("sleepHrOnly")) null else j.getBoolean("sleepHrOnly"))
    }
}
