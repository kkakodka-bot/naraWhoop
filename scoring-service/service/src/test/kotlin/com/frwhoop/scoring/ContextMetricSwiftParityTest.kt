package com.frwhoop.scoring

import com.frwhoop.scoring.scoring.*
import com.noop.analytics.*
import com.noop.data.DailyMetric
import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** Pinned actual Swift outputs; the Swift app-host test independently checks this same fixture. */
class ContextMetricSwiftParityTest {
    private val day = "2026-09-18"
    private val source = "synthetic-context-source"
    private val lo = LocalDate.parse(day).atStartOfDay(ZoneId.of("UTC")).toEpochSecond()
    private fun empty() = HistoricalContextInputs(day, "UTC", emptyList(), emptyMap(), emptyList(),
        emptyList(), emptyList(), emptyList(), emptyList(), false, false, emptyMap(), emptyList())
    private fun state(base: Double, spread: Double) = BaselineState(base, spread, 50, 0, BaselineStatus.TRUSTED)

    @Test fun actualServerContextOrchestrationMatchesSwiftEngineVectors() {
        val fixture = JSONObject(File("../../Tests/Fixtures/context-metrics-swift-v1.json").readText())
        val hr = listOf(60, 75, 100).flatMapIndexed { index, bpm ->
            (0L until 300L).map { HrSample(source, lo + (8 + index) * 3600 + it, bpm) }
        }
        val rr = hr.mapIndexed { index, s -> RrInterval(source, s.ts, 800 + index % 2 * 40) }
        val stressInput = empty().copy(hr = hr, rr = rr, baselinesBefore = mapOf("daytime_hr" to state(50.0, 3.0)))
        fun stress(personal: Boolean): JSONObject {
            val r = ContextMetricOrchestrator.evaluate(stressInput.copy(daytimePersonalBaselineEnabled = personal))
            val detail = r.details.getJSONObject("daytimeStress")
            return JSONObject().put("mean", r.metrics.getJSONObject("daytime_stress_mean").get("value"))
                .put("highMinutes", r.metrics.getJSONObject("daytime_stress_high_min").get("value"))
                .put("levels", JSONArray(r.charts.getJSONArray("daytime_stress").let { a ->
                    (0 until a.length()).map { a.getJSONObject(it).get("value") }
                })).put("hrOnlyFallback", detail.getBoolean("hrOnlyFallback"))
                .put("sustainedHigh", detail.getBoolean("sustainedHigh"))
        }
        val history = (0 until 35).map { i ->
            val d = LocalDate.parse(day).minusDays((34 - i).toLong()).toString()
            val recent = i >= 33
            HistoricalDailyObservation(d, DailyMetric(source, d, restingHr = if (recent) 75 else 55,
                avgHrv = if (recent) 15.0 else 55.0, respRateBpm = if (recent) 25.0 else 14.0,
                skinTempDevC = if (recent) 1.0 else 0.0, skinTempC = 35.0))
        }
        val flags = listOf("alcohol", "stress", "sauna", "hardOrLateWorkout", "travelPhaseJump", "alreadyUnwell").associateWith { false }
        // Genuine state before D: today's observation is never used to manufacture eligibility.
        // The actual Swift formula fixture remains unchanged; absolute skin temperature only seeds
        // its independent eligibility state, never replaces the named deviation supplied to illness.
        val preceding = history.dropLast(1).map { it.daily }
        val illnessBefore = mapOf(
            "resting_hr" to Baselines.foldHistory(preceding.map { it.restingHr?.toDouble() }, Baselines.restingHRCfg),
            "hrv" to Baselines.foldHistory(preceding.map { it.avgHrv }, Baselines.hrvCfg),
            "resp" to Baselines.foldHistory(preceding.map { it.respRateBpm }, Baselines.respCfg),
            "skin_temp" to Baselines.foldHistory(preceding.map { it.skinTempC }, Baselines.metricCfg.getValue("skin_temp")))
        assertTrue(illnessBefore.values.all { it.trusted && it.nValid >= 14 })
        val illnessInput = empty().copy(history = history, baselinesBefore = illnessBefore, journalEnabled = true,
            contextFlags = flags, baselineEpochSeconds = illnessBefore.keys.associateWith { 0.0 })
        fun illness(alcohol: Boolean): JSONObject {
            val r = ContextMetricOrchestrator.evaluate(illnessInput.copy(contextFlags = flags + ("alcohol" to alcohol)))
            val d = r.details.getJSONObject("illness")
            return JSONObject().put("score", r.metrics.getJSONObject("illness_score").get("value"))
                .put("level", d.get("level")).put("signalCount", d.get("signalCount")).put("suppressedBy", d.get("suppressedBy"))
        }
        val ill = ContextMetricOrchestrator.evaluate(illnessInput)
        val hours = (0L until 14L).flatMap { back -> (0..23).map { hour ->
            HistoricalHourlyObservation(lo - back * 86400 + hour * 3600, 65 + 10 * cos(2 * PI * (hour - 16) / 24), 100)
        }}
        val circadian = ContextMetricOrchestrator.evaluate(empty().copy(hourlyHr = hours,
            sleepBounds = listOf(SleepBounds(lo - 3600, lo + 7 * 3600))))
        val circadianDetail = circadian.details.getJSONObject("circadian")
        val states = mapOf("skin_temp" to state(35.0, .3), "resting_hr" to state(55.0, 2.0), "hrv" to state(55.0, 5.0))
        val cycleHistory = (0 until 60).map { i ->
            val d = LocalDate.parse(day).minusDays((59 - i).toLong()).toString()
            val wave = sin(2 * PI * i / 28)
            HistoricalDailyObservation(d, DailyMetric(source, d, skinTempC = 35 + .5 * wave,
                restingHr = 55 + (3 * wave).toInt(), avgHrv = 55 - 8 * wave), states)
        }
        val cycle = ContextMetricOrchestrator.evaluate(empty().copy(history = cycleHistory, baselinesBefore = states,
            cycleEnabled = true, periodStarts = listOf("2026-08-01", "2026-08-29"),
            baselineEpochSeconds = states.keys.associateWith { 0.0 }))
        val cycleDetail = cycle.details.getJSONObject("cycle")
        val stress = ContextMetricOrchestrator.evaluate(stressInput)
        val parts = StressIndex.components(rr)!!
        val frequency = stress.details.getJSONObject("frequencyHrv")
        val actual = JSONObject().put("schema", 1).put("recipe", "context-engine-synthetic-v1").put("timezone", "UTC")
            .put("dayRelative", stress(false)).put("personalBaseline", stress(true))
            .put("illness", illness(false)).put("suppressedIllness", illness(true))
            .put("distance", JSONObject().put("value", ill.metrics.getJSONObject("illness_distance").get("value"))
                .put("fires", ill.details.getJSONObject("illness").get("distanceFires")))
            .put("circadian", JSONObject().put("phaseHour", circadian.metrics.getJSONObject("circadian_phase_hour").get("value"))
                .put("offsetMinutes", circadian.metrics.getJSONObject("circadian_offset_min").get("value"))
                .put("confidence", circadianDetail.get("confidence")).put("acrophase", circadianDetail.get("acrophaseHours")))
            .put("cycle", JSONObject().put("phase", cycleDetail.get("phase")).put("confidence", cycleDetail.get("confidence"))
                .put("dayLow", cycleDetail.get("cycleDayLow")).put("dayHigh", cycleDetail.get("cycleDayHigh"))
                .put("length", cycleDetail.get("cycleLengthDays")).put("markers", cycleDetail.get("shiftMarkers"))
                .put("index", JSONArray(cycle.charts.getJSONArray("cycle_index").let { a ->
                    (0 until a.length()).map { a.getJSONObject(it).get("value") }
                })))
            .put("stressIndex", JSONObject().put("value", stress.metrics.getJSONObject("baevsky_stress_index").get("value"))
                .put("modeSeconds", parts.moSec).put("modePercent", parts.aMoPercent).put("rangeSeconds", parts.mxDMnSec))
            .put("frequency", JSONObject().put("lf", frequency.get("lfPower")).put("hf", frequency.get("hfPower"))
                .put("ratio", frequency.get("lfHfRatio")))
        compare(actual, fixture, "root")
    }

    private fun compare(actual: Any, expected: Any, path: String) {
        when {
            actual is JSONObject && expected is JSONObject -> {
                assertEquals(path, expected.keySet(), actual.keySet())
                for (key in expected.keySet()) compare(actual.get(key), expected.get(key), "$path.$key")
            }
            actual is JSONArray && expected is JSONArray -> {
                assertEquals(path, expected.length(), actual.length())
                for (i in 0 until expected.length()) compare(actual.get(i), expected.get(i), "$path[$i]")
            }
            actual is Number && expected is Number -> assertEquals(path, expected.toDouble(), actual.toDouble(),
                maxOf(1e-8, kotlin.math.abs(expected.toDouble()) * 1e-9))
            else -> assertEquals(path, expected, actual)
        }
    }
}
