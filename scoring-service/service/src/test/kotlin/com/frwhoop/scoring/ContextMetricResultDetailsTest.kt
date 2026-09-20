package com.frwhoop.scoring

import com.frwhoop.scoring.scoring.*
import com.noop.analytics.*
import com.noop.data.DailyMetric
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneOffset
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

class ContextMetricResultDetailsTest {
    private val day = LocalDate.parse("2026-09-18")
    private val lo = day.atStartOfDay(ZoneOffset.UTC).toEpochSecond()
    private val source = "synthetic-context-details"
    private val flags = listOf("alcohol", "stress", "sauna", "hardOrLateWorkout", "travelPhaseJump", "alreadyUnwell")
        .associateWith { false }
    private fun empty() = HistoricalContextInputs(day.toString(), "UTC", emptyList(), emptyMap(),
        emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), false, false, emptyMap(), emptyList())
    private fun wire(input: HistoricalContextInputs): JSONObject = JSONObject(
        ServerDerivedMetrics().withContext(ContextMetricOrchestrator.evaluate(input)).details.toString())

    private fun illnessInput(raised: Boolean): HistoricalContextInputs {
        val history = (0 until 35).map { n ->
            val key = day.minusDays((34 - n).toLong()).toString()
            val recent = raised && n >= 33
            HistoricalDailyObservation(key, DailyMetric(source, key, restingHr = if (recent) 75 else 55,
                avgHrv = if (recent) 15.0 else 55.0, respRateBpm = if (recent) 25.0 else 14.0,
                skinTempDevC = if (recent) 1.0 else 0.0, skinTempC = 35.0))
        }
        val prior = history.dropLast(1).map { it.daily }
        val before = mapOf(
            "resting_hr" to Baselines.foldHistory(prior.map { it.restingHr?.toDouble() }, Baselines.restingHRCfg),
            "hrv" to Baselines.foldHistory(prior.map { it.avgHrv }, Baselines.hrvCfg),
            "resp" to Baselines.foldHistory(prior.map { it.respRateBpm }, Baselines.respCfg),
            "skin_temp" to Baselines.foldHistory(prior.map { it.skinTempC }, Baselines.metricCfg.getValue("skin_temp")))
        return empty().copy(history = history, baselinesBefore = before, journalEnabled = true,
            contextFlags = flags, baselineEpochSeconds = before.keys.associateWith { 0.0 })
    }

    @Test fun illnessCopiesExactEngineTextAndActualEmptyLabelsForEveryEmittedContext() {
        for ((raised, context) in listOf(
            true to IllnessSignalEngine.Context(),
            true to IllnessSignalEngine.Context(alcohol = true, stress = true),
            true to IllnessSignalEngine.Context(alreadyUnwell = true),
            false to IllnessSignalEngine.Context(),
        )) {
            val input = illnessInput(raised).copy(contextFlags = flags + mapOf(
                "alcohol" to context.alcohol, "stress" to context.stress, "alreadyUnwell" to context.alreadyUnwell))
            fun reading(value: Double, base: Double, cfg: MetricCfg, sign: Double = 1.0) =
                IllnessSignalEngine.SignalReading(sign * Baselines.deviation(value,
                    Baselines.foldHistory(List(28) { base }, cfg)).z)
            val expected = IllnessSignalEngine.evaluate(IllnessSignalEngine.Inputs(
                reading(if (raised) 75.0 else 55.0, 55.0, Baselines.restingHRCfg),
                IllnessSignalEngine.SignalReading(if (raised) 1.0 / .3 else 0.0),
                reading(if (raised) 15.0 else 55.0, 55.0, Baselines.hrvCfg, -1.0),
                reading(if (raised) 25.0 else 14.0, 14.0, Baselines.respCfg)), context)
            val actual = wire(input).getJSONObject("illness")
            assertEquals(expected.copy, actual.getString("copy"))
            assertEquals(expected.firedSignals, actual.getJSONArray("firedSignals").toList())
            assertEquals(expected.level.raw, actual.getString("level"))
            assertEquals(expected.suppressedBy, actual.getJSONArray("suppressedBy").toList())
            assertEquals(expected.signalCount, actual.getInt("signalCount"))
            assertEquals(emptyList<String>(), actual.getJSONArray("firedSignals").toList())
            if (raised) {
                assertTrue(actual.getInt("signalCount") > 0)
                assertTrue(actual.getString("copy").contains(IllnessSignalEngine.disclaimerTail))
            }
        }
    }

    @Test fun distanceDetailsAndScalarComeFromTheSameActualKernelResult() {
        for (raised in listOf(false, true)) for (alcohol in listOf(false, true)) {
            val input = illnessInput(raised).copy(contextFlags = flags + ("alcohol" to alcohol))
            fun z(value: Double, base: Double, cfg: MetricCfg) = Baselines.deviation(value,
                Baselines.foldHistory(List(28) { base }, cfg)).z
            val expected = IllnessDistance.evaluate(IllnessDistance.FeatureVector(
                z(if (raised) 75.0 else 55.0, 55.0, Baselines.restingHRCfg),
                -z(if (raised) 15.0 else 55.0, 55.0, Baselines.hrvCfg),
                if (raised) 1.0 / .3 else 0.0,
                z(if (raised) 25.0 else 14.0, 14.0, Baselines.respCfg)))
            val result = ContextMetricOrchestrator.evaluate(input)
            val actual = wire(input).getJSONObject("illness")
            val metric = result.metrics.getJSONObject("illness_distance")
            assertEquals(expected.distance, metric.getDouble("value"), 1e-12)
            assertEquals("dimensionless", metric.getString("unit"))
            assertEquals("IllnessDistance_identity_correlation", metric.getString("method"))
            assertEquals(expected.deviatingFeatures, actual.getInt("distanceDeviatingFeatures"))
            assertEquals(expected.fires, actual.getBoolean("distanceFires"))
            assertEquals(expected.usedDiagonalFallback, actual.getBoolean("distanceUsedDiagonalFallback"))
            assertFalse(actual.getBoolean("distanceUsedDiagonalFallback")) // Identity is invertible.
            assertFalse(actual.getBoolean("distanceIsAlertGate"))
            assertTrue(actual.getBoolean("wellnessOnly"))
            assertTrue("illness_distance" in result.capabilities)
        }
    }

    @Test fun distanceFeatureCountIsNotTheIllnessSignalCountAtTheExactThreshold() {
        val base = illnessInput(false)
        val input = base.copy(history = base.history.map { row ->
            if (row.day >= day.minusDays(1).toString())
                row.copy(daily = row.daily.copy(skinTempDevC = .6)) else row
        })
        val expected = IllnessDistance.evaluate(IllnessDistance.FeatureVector(0.0, 0.0, 2.0, 0.0))
        val actual = wire(input).getJSONObject("illness")
        assertEquals(0, actual.getInt("signalCount")) // SignalEngine uses strictly greater than 2.
        assertEquals(1, expected.deviatingFeatures) // Distance includes exactly 2.
        assertEquals(expected.deviatingFeatures, actual.getInt("distanceDeviatingFeatures"))
        assertEquals(expected.usedDiagonalFallback, actual.getBoolean("distanceUsedDiagonalFallback"))
        assertEquals(expected.fires, actual.getBoolean("distanceFires"))
        assertEquals(expected.distance,
            ContextMetricOrchestrator.evaluate(input).metrics.getJSONObject("illness_distance").getDouble("value"), 0.0)
    }

    @Test fun unavailableFamiliesStayNullInsteadOfInventingRequiredResultFields() {
        val base = illnessInput(true)
        for (input in listOf(empty(), base.copy(journalEnabled = false),
            base.copy(contextFlags = flags + ("alcohol" to null)), base.copy(baselinesBefore = emptyMap()))) {
            val actual = wire(input)
            for (key in listOf("illness", "cycle", "circadian")) {
                assertTrue(actual.has(key))
                assertSame(JSONObject.NULL, actual.get(key))
            }
            assertFalse(actual.has("note")); assertFalse(actual.has("copy")); assertFalse(actual.has("firedSignals"))
            assertFalse(actual.has("distanceDeviatingFeatures")); assertFalse(actual.has("distanceUsedDiagonalFallback"))
            val result = ContextMetricOrchestrator.evaluate(input)
            assertTrue(result.metrics.getJSONObject("illness_distance").isNull("value"))
            assertFalse("illness_distance" in result.capabilities)
        }
    }

    private fun cycleInput(flat: Boolean = false): HistoricalContextInputs {
        val before = mapOf("skin_temp" to BaselineState(35.0, .3, 50, 0, BaselineStatus.TRUSTED),
            "resting_hr" to BaselineState(55.0, 2.0, 50, 0, BaselineStatus.TRUSTED),
            "hrv" to BaselineState(55.0, 5.0, 50, 0, BaselineStatus.TRUSTED))
        val history = (0 until 60).map { n ->
            val key = day.minusDays((59 - n).toLong()).toString()
            val wave = if (flat) 0.0 else sin(2 * PI * n / 28)
            HistoricalDailyObservation(key, DailyMetric(source, key, skinTempC = 35 + .5 * wave,
                restingHr = 55 + (3 * wave).toInt(), avgHrv = 55 - 8 * wave), before)
        }
        return empty().copy(history = history, baselinesBefore = before, cycleEnabled = true,
            periodStarts = listOf("2026-08-01", "2026-08-29"), baselineEpochSeconds = before.keys.associateWith { 0.0 })
    }

    private fun expectedCycle(input: HistoricalContextInputs): CyclePhaseEngine.Result = CyclePhaseEngine.classifyCalendar(
        input.history.map { row ->
            fun z(value: Double?, key: String) = value?.let { Baselines.deviation(it, row.baselinesBefore.getValue(key)).z }
            CyclePhaseEngine.Night(row.day, z(row.daily.skinTempC, "skin_temp"),
                z(row.daily.restingHr?.toDouble(), "resting_hr"), z(row.daily.avgHrv, "hrv"))
        }, true, input.day, input.periodStarts)

    @Test fun observedCycleNoteIsTheActualKernelResultNotAStaticAwarenessLabel() {
        val input = cycleInput()
        val expected = expectedCycle(input)
        val actual = wire(input).getJSONObject("cycle")
        assertNotEquals(CyclePhaseEngine.Phase.LEARNING, expected.phase)
        assertEquals(expected.phase.raw, actual.getString("phase"))
        assertEquals(expected.note, actual.getString("note"))
        assertNotEquals(CyclePhaseEngine.awarenessLine, actual.getString("note"))
    }

    @Test fun enabledColdStartPreservesKernelLearningNoteWithoutInventingAPhase() {
        val input = empty().copy(cycleEnabled = true)
        val expected = CyclePhaseEngine.classifyCalendar(emptyList(), false, input.day)
        val actual = wire(input).getJSONObject("cycle")
        assertEquals("learning", actual.getString("phase"))
        assertEquals(expected.note, actual.getString("note"))
        assertTrue(actual.isNull("cycleLengthDays"))
        assertEquals(0, actual.getJSONArray("shiftMarkers").length())
    }

    @Test fun observedFlatCyclePreservesUnknownNoteRatherThanLearningOrConfidentText() {
        val input = cycleInput(flat = true)
        val expected = expectedCycle(input)
        val actual = wire(input).getJSONObject("cycle")
        assertEquals(CyclePhaseEngine.Phase.UNKNOWN, expected.phase)
        assertEquals(expected.phase.raw, actual.getString("phase"))
        assertEquals(expected.note, actual.getString("note"))
    }

    private fun circadianInput(amplitude: Double, schedule: Boolean = true) = empty().copy(
        hourlyHr = (0L until 14).flatMap { back -> (0..23).map { hour ->
            HistoricalHourlyObservation(lo - back * 86400 + hour * 3600,
                65 + amplitude * cos(2 * PI * (hour - 16) / 24), 100)
        } }, sleepBounds = if (schedule) listOf(SleepBounds(lo - 3600, lo + 7 * 3600)) else emptyList())

    private fun expectedPhase(input: HistoricalContextInputs): CircadianEngine.PhaseEstimate = requireNotNull(
        CircadianEngine.estimatePhase(input.hourlyHr.groupBy {
            java.time.Instant.ofEpochSecond(it.start).atZone(ZoneOffset.UTC).hour
        }.toSortedMap().map { (hour, samples) -> CircadianEngine.ActivityBin(hour.toDouble(), samples.map { it.meanHr }.average()) }, 14, 7.0))

    @Test fun readableWideAndUnreadableCircadianNotesMatchActualEngineExactly() {
        val confidences = mutableListOf<CircadianEngine.PhaseConfidence>()
        for (amplitude in listOf(10.0, 5.0, 0.0)) {
            val input = circadianInput(amplitude)
            val expected = expectedPhase(input)
            val actual = wire(input).getJSONObject("circadian")
            assertEquals(expected.note, actual.getString("note"))
            assertEquals(expected.confidence.raw, actual.getString("confidence"))
            confidences += expected.confidence
        }
        assertEquals(listOf(CircadianEngine.PhaseConfidence.SOLID, CircadianEngine.PhaseConfidence.WIDE,
            CircadianEngine.PhaseConfidence.UNREADABLE), confidences)
    }

    @Test fun missingScheduleKeepsActualPhaseNoteButDoesNotAddOffsetCapability() {
        val input = circadianInput(10.0, schedule = false)
        val expected = expectedPhase(input)
        val result = ContextMetricOrchestrator.evaluate(input)
        val actual = wire(input).getJSONObject("circadian")
        assertEquals(expected.note, actual.getString("note"))
        assertTrue(actual.isNull("habitualWakeHour"))
        assertTrue(result.metrics.getJSONObject("circadian_offset_min").isNull("value"))
        assertFalse("circadian_offset_min" in result.capabilities)
    }
}
