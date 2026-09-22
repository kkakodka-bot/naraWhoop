package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.DayResult
import com.noop.data.DailyMetric
import org.json.JSONObject
import java.time.LocalDate

/** Only checkpoint observations from this source era; each night keeps its own before-state. */
object HistoricalContextInputFactory {
    fun build(input:SignalSampleReader.DayInputs,result:DayResult,p:HistoricalStateMachine.Prepared,
              napOverrides:Map<SleepBounds,Boolean> = emptyMap()):HistoricalContextInputs {
        val end=LocalDate.parse(input.day)
        val cutoff=end.minusDays(364).toString()
        val rows=p.history.filter { it.getString("day")>=cutoff && it.getString("day")<input.day }
        val byDay=rows.associateBy { it.getString("day") }
        // Empty calendar slots are missing observations, not a compressed sequence of valid nights.
        // Do not pad a cold start with fictitious pre-installation days.
        val first=rows.firstOrNull()?.getString("day")?.let(LocalDate::parse) ?: end
        val history=generateSequence(first) { it.plusDays(1) }.takeWhile { it<=end }.map { date ->
            val key=date.toString()
            if(key==input.day) HistoricalDailyObservation(key,result.daily,p.baselines)
            else byDay[key]?.let { row -> HistoricalDailyObservation(key,DailyMetricJson.decode(row.getJSONObject("daily")),
                HistoricalStateMachine.decodeBaselines(row.getJSONObject("baselinesBefore"))) }
                ?: HistoricalDailyObservation(key,DailyMetric(input.deviceId,key))
        }.toList()
        val hourly=rows.flatMap { row ->
            // Old elapsed-hour bins cannot be re-bucketed accurately without their raw observations.
            if(row.optInt("hourlyHrSchemaVersion",0)!=2) return@flatMap emptyList()
            val a=row.optJSONArray("hourlyHr") ?: return@flatMap emptyList()
            (0 until a.length()).map { a.getJSONObject(it).let { h -> HistoricalHourlyObservation(h.getLong("start"),h.getDouble("meanHr"),h.getInt("sampleCount")) } }
        }+HistoricalObservationWindows.hourlyHr(input)
        val sleep=rows.mapNotNull { row ->
            row.optJSONObject("mainNightBounds")?.let { SleepBounds(it.getLong("start"),it.getLong("end")) }
        }+listOfNotNull(HistoricalObservationWindows.mainNight(input,result,p.habitualMidsleep,napOverrides))
        val flags=input.history.values.singleOrNull { it.kind=="context" && !it.deleted && it.payload.optString("day")==input.day }
            ?.payload?.getJSONObject("flags") ?: JSONObject()
        val config=input.history.configuration
        return HistoricalContextInputs(input.day,input.timezone,history,p.baselines,input.hr,input.rr,input.gravity,sleep,hourly,
            config.optBoolean("journalContextEnabled",false),config.optBoolean("cycleAwarenessEnabled",false),
            listOf("alcohol","stress","sauna","hardOrLateWorkout","travelPhaseJump","alreadyUnwell").associateWith {
                if(flags.isNull(it)) null else flags.getBoolean(it)
            },input.history.values.filter { it.kind=="period" && !it.deleted }.map { it.payload.getString("day") }.filter { it<=input.day },
            config.optBoolean("daytimePersonalBaselineEnabled",false),p.baselineEpochSeconds)
    }
}
