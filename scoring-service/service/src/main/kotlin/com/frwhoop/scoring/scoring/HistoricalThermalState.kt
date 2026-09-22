package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.*
import com.noop.protocol.DeviceFamily
import com.noop.protocol.Whoop4SkinTemp
import org.json.JSONObject
import java.time.LocalDate
import java.time.ZoneOffset

/** Re-evaluates strictly earlier thermal evidence on today's as-of window-wide WHOOP4 anchor. */
internal object HistoricalThermalState {
    fun observedRawHistogram(input:SignalSampleReader.DayInputs,result:DayResult):JSONObject {
        val worn=input.hr.filter { it.bpm in 30..220 }.map { it.ts }.toHashSet()
        val counts=input.skinTemp.filter { t -> t.ts in worn && t.raw in Whoop4SkinTemp.WORN_MIN_RAW..Whoop4SkinTemp.WORN_MAX_RAW &&
            result.sleepSessions.any { t.ts in it.start..it.end } }.groupingBy { it.raw }.eachCount()
        return JSONObject(counts.mapKeys { it.key.toString() })
    }

    fun baseline(history:List<JSONObject>,day:String,epoch:Double,anchor:Double?):BaselineState {
        val cfg=Baselines.metricCfg.getValue("skin_temp")
        val byDay=history.associateBy { it.getString("day") }
        var cursor=history.firstOrNull()?.getString("day")?.let(LocalDate::parse) ?: LocalDate.parse(day)
        val end=LocalDate.parse(day)
        var state:BaselineState?=null
        while(cursor<end) {
            if(cursor.atStartOfDay(ZoneOffset.UTC).toEpochSecond()>=epoch) {
                val counts=byDay[cursor.toString()]?.optJSONObject("whoop4WornNightRawCounts")
                val value=counts?.let { AnalyticsEngine.skinTempHistogramMean(it.keySet().associate { key -> key.toInt() to it.getInt(key) },
                    DeviceFamily.WHOOP4,anchor) }
                state=Baselines.update(state,value,cfg)
            }
            cursor=cursor.plusDays(1)
        }
        return state ?: Baselines.foldHistory(emptyList(),cfg)
    }
}
