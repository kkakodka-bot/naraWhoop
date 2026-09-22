package com.frwhoop.scoring

import com.frwhoop.scoring.db.HistoryCheckpointReader
import com.frwhoop.scoring.db.HistoryInputReader
import com.frwhoop.scoring.db.SignalSampleReader
import com.frwhoop.scoring.scoring.*
import com.noop.analytics.*
import com.noop.data.DailyMetric
import com.noop.data.HrSample
import com.noop.data.RrInterval
import com.noop.protocol.DeviceFamily
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.util.UUID
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

class ContextMetricOrchestratorTest {
    private val day = "2026-09-18"
    private val source = "canonical-source"
    private val allNo = listOf("alcohol", "stress", "sauna", "hardOrLateWorkout", "travelPhaseJump", "alreadyUnwell").associateWith { false }
    private val selectors: Map<String, (DailyMetric) -> Double?> = linkedMapOf(
        "resting_hr" to { it.restingHr?.toDouble() }, "hrv" to { it.avgHrv },
        "resp" to { it.respRateBpm }, "skin_temp" to { it.skinTempC })
    private val noReset = selectors.keys.associateWith { 0.0 }
    private fun empty() = HistoricalContextInputs(day, "UTC", emptyList(), emptyMap(), emptyList(), emptyList(),
        emptyList(), emptyList(), emptyList(), false, false, emptyMap(), emptyList())
    private fun state(value: Double, spread: Double) = BaselineState(value, spread, 50, 0, BaselineStatus.TRUSTED)
    private fun history(count: Int = 35): List<HistoricalDailyObservation> = (0 until count).map { i ->
        val date = LocalDate.parse(day).minusDays((count - i - 1).toLong()).toString()
        val recent = i >= count - 2
        HistoricalDailyObservation(date, DailyMetric(source, date, restingHr = if (recent) 75 else 55,
            avgHrv = if (recent) 15.0 else 55.0, respRateBpm = if (recent) 25.0 else 14.0,
            skinTempDevC = if (recent) 1.0 else 0.0, skinTempC = 35.0))
    }
    private fun epoch(date: String) = LocalDate.parse(date).atStartOfDay(ZoneOffset.UTC).toEpochSecond().toDouble()
    private fun illnessInput(rows: List<HistoricalDailyObservation> = history(), epochs: Map<String, Double> = noReset): HistoricalContextInputs {
        val dates = generateSequence(LocalDate.parse(rows.minOf { it.day })) { it.plusDays(1) }
            .takeWhile { it < LocalDate.parse(day) }.map { it.toString() }.toList()
        val byDay = rows.associateBy { it.day }
        val before = selectors.mapValues { (key, select) -> Baselines.foldHistory(
            dates.map { byDay[it]?.daily?.let(select) }, dates, Baselines.metricCfg.getValue(key), epochs.getValue(key)) }
        return empty().copy(history = rows, baselinesBefore = before, journalEnabled = true,
            contextFlags = allNo, baselineEpochSeconds = epochs)
    }
    private fun assertUnavailable(result: HistoricalContextResult, gap: String) {
        assertTrue(result.metrics.getJSONObject("illness_score").isNull("value"))
        assertTrue(result.metrics.getJSONObject("illness_distance").isNull("value"))
        assertTrue(result.details.isNull("illness"))
        assertFalse(result.capabilities.contains("illness_score"))
        assertFalse(result.capabilities.contains("illness_distance"))
        assertTrue("missing $gap in ${result.gaps}", result.gaps.contains(gap))
    }
    private fun assertSignals(result: HistoricalContextResult, rhr: Double? = 75.0, hrv: Double? = 15.0,
                              resp: Double? = 25.0, skin: Double? = 1.0) {
        fun z(value: Double?, baseline: Double, key: String, sign: Int = 1) = value?.let {
            Baselines.deviation(it, Baselines.foldHistory(List(28) { baseline }, Baselines.metricCfg.getValue(key))).z * sign
        }
        val r = z(rhr, 55.0, "resting_hr"); val h = z(hrv, 55.0, "hrv", -1)
        val p = z(resp, 14.0, "resp"); val s = skin?.div(.3)
        fun reading(v: Double?) = v?.let { IllnessSignalEngine.SignalReading(it) }
        val expected = IllnessSignalEngine.evaluate(IllnessSignalEngine.Inputs(reading(r), reading(s), reading(h), reading(p)),
            IllnessSignalEngine.Context())
        val distance = IllnessDistance.evaluate(IllnessDistance.FeatureVector(r, h, s, p))
        assertEquals(expected.score, result.metrics.getJSONObject("illness_score").getDouble("value"), 1e-12)
        assertEquals(expected.level.raw, result.details.getJSONObject("illness").getString("level"))
        assertEquals(expected.signalCount, result.details.getJSONObject("illness").getInt("signalCount"))
        assertEquals(distance.distance, result.metrics.getJSONObject("illness_distance").getDouble("value"), 1e-12)
    }

    @Test fun missingConsentAndObservationsStayUnavailableNotZeroOrQuiet() {
        val result = ContextMetricOrchestrator.evaluate(empty())
        for (key in listOf("illness_score", "illness_distance", "daytime_stress_mean", "daytime_stress_high_min", "baevsky_stress_index", "circadian_phase_hour")) {
            assertTrue(key, result.metrics.getJSONObject(key).isNull("value"))
        }
        assertTrue(result.details.isNull("illness")); assertTrue(result.details.isNull("cycle"))
        assertTrue(result.capabilities.isEmpty())
        assertTrue(result.gaps.containsAll(listOf("journal_context_not_shared", "cycle_context_not_shared")))
        assertEquals(mapOf("daytime_hr" to null, "daytime_rmssd" to null), result.baselineObservations)
    }

    @Test fun illnessMatchesExistingFormulasAndUnknownConfounderIsNotFalse() {
        val rows = history()
        val input = illnessInput(rows)
        assertTrue(input.baselinesBefore.values.all { it.trusted && it.nValid >= 14 })
        val result = ContextMetricOrchestrator.evaluate(input)
        val base = rows.takeLast(31).dropLast(3).map { it.daily }
        val rhr = Baselines.deviation(75.0, Baselines.foldHistory(base.map { it.restingHr?.toDouble() }, Baselines.restingHRCfg)).z
        val hrv = -Baselines.deviation(15.0, Baselines.foldHistory(base.map { it.avgHrv }, Baselines.hrvCfg)).z
        val resp = Baselines.deviation(25.0, Baselines.foldHistory(base.map { it.respRateBpm }, Baselines.respCfg)).z
        val expected = IllnessSignalEngine.evaluate(IllnessSignalEngine.Inputs(
            IllnessSignalEngine.SignalReading(rhr), IllnessSignalEngine.SignalReading(1.0 / 0.3),
            IllnessSignalEngine.SignalReading(hrv), IllnessSignalEngine.SignalReading(resp)), IllnessSignalEngine.Context())
        assertEquals(expected.score, result.metrics.getJSONObject("illness_score").getDouble("value"), 1e-12)
        assertEquals(expected.level.raw, result.details.getJSONObject("illness").getString("level"))
        val distance = IllnessDistance.evaluate(IllnessDistance.FeatureVector(rhr, hrv, 1.0 / 0.3, resp))
        assertEquals(distance.distance, result.metrics.getJSONObject("illness_distance").getDouble("value"), 1e-12)
        assertFalse(result.details.getJSONObject("illness").getBoolean("distanceIsAlertGate"))
        val suppressed = ContextMetricOrchestrator.evaluate(input.copy(contextFlags = allNo + ("alcohol" to true)))
        assertEquals("suppressed", suppressed.details.getJSONObject("illness").getString("level"))
        val unknown = ContextMetricOrchestrator.evaluate(input.copy(contextFlags = allNo + ("alcohol" to null)))
        assertTrue(unknown.metrics.getJSONObject("illness_score").isNull("value"))
        assertTrue(unknown.gaps.contains("journal_context_incomplete"))
    }

    @Test fun oldHistoryCannotBecomeTrustedIllnessAcross180MissingDays() {
        val rows = history().map { row ->
            if (row.day == day) row else {
                val oldDay = LocalDate.parse(row.day).minusDays(180).toString()
                row.copy(day = oldDay, daily = row.daily.copy(day = oldDay))
            }
        }
        val input = illnessInput(rows)
        assertTrue(input.baselinesBefore.values.all { it.status == BaselineStatus.STALE })
        assertUnavailable(ContextMetricOrchestrator.evaluate(input), "illness_baseline_stale")
    }

    @Test fun missingYesterdayIsNotReplacedWithAnOlderObservation() {
        val yesterday = LocalDate.parse(day).minusDays(1).toString()
        val rows = history().filter { it.day != yesterday }.map { row ->
            if (row.day != day) row else row.copy(daily = row.daily.copy(restingHr = 60,
                avgHrv = 50.0, respRateBpm = 15.0, skinTempDevC = .1))
        }
        val input = illnessInput(rows)
        assertTrue(input.baselinesBefore.values.all { it.trusted })
        assertSignals(ContextMetricOrchestrator.evaluate(input), 60.0, 50.0, 15.0, .1)
        // Explicit missing slots and sparse observations have identical calendar semantics.
        val padded = input.copy(history = rows + HistoricalDailyObservation(yesterday, DailyMetric(source, yesterday)))
        assertTrue(ContextMetricOrchestrator.evaluate(input).metrics.similar(ContextMetricOrchestrator.evaluate(padded).metrics))
    }

    @Test fun emptyOrAbsentTodayCannotPublishYesterdaysPhysiology() {
        val rows = history()
        for (current in listOf<DailyMetric?>(null, DailyMetric(source, day, skinTempC = 35.0),
            DailyMetric(source, day, avgHrv = Double.NaN, respRateBpm = Double.POSITIVE_INFINITY, skinTempDevC = 11.0))) {
            val changed = rows.dropLast(1) + listOfNotNull(current?.let { HistoricalDailyObservation(day, it) })
            assertUnavailable(ContextMetricOrchestrator.evaluate(illnessInput(changed)), "current_day_physiology_unavailable")
        }
    }

    @Test fun sparseBaselineCannotBorrowTrustedNightsFromOutsideThe28DayWindow() {
        val end = LocalDate.parse(day)
        val rows = history(70).filter { row ->
            val d = LocalDate.parse(row.day)
            d < end.minusDays(30) || d > end.minusDays(3) || d in end.minusDays(15)..end.minusDays(3)
        }
        val input = illnessInput(rows)
        assertTrue("long-running before-state remains trusted", input.baselinesBefore.values.all { it.trusted })
        assertUnavailable(ContextMetricOrchestrator.evaluate(input), "illness_baseline_learning")
    }

    @Test fun eachStaleMetricIsExcludedEvenWhenAnotherMetricRemainsTrusted() {
        val cutoff = LocalDate.parse(day).minusDays(16).toString()
        for (key in selectors.keys) {
            val rows = history().map { row ->
                if (row.day < cutoff || row.day == day) row else row.copy(daily = when (key) {
                    "resting_hr" -> row.daily.copy(restingHr = null)
                    "hrv" -> row.daily.copy(avgHrv = null)
                    "resp" -> row.daily.copy(respRateBpm = null)
                    else -> row.daily.copy(skinTempC = null)
                })
            }
            val input = illnessInput(rows)
            assertEquals(key, BaselineStatus.STALE, input.baselinesBefore.getValue(key).status)
            val result = ContextMetricOrchestrator.evaluate(input)
            assertSignals(result, if (key == "resting_hr") null else 75.0, if (key == "hrv") null else 15.0,
                if (key == "resp") null else 25.0, if (key == "skin_temp") null else 1.0)
            assertTrue(result.gaps.contains("illness_baseline_stale"))
        }
    }

    @Test fun missingPreparedStatesAndUnknownResetPolicyCannotResurrectHistory() {
        val input = illnessInput()
        assertUnavailable(ContextMetricOrchestrator.evaluate(input.copy(baselinesBefore = emptyMap())), "illness_baseline_learning")
        for (policy in listOf(emptyMap(), noReset.mapValues { Double.NaN }, noReset.mapValues { -1.0 },
            noReset.mapValues { Double.POSITIVE_INFINITY })) {
            assertUnavailable(ContextMetricOrchestrator.evaluate(input.copy(baselineEpochSeconds = policy)), "illness_reset_policy_unavailable")
        }
        assertSignals(ContextMetricOrchestrator.evaluate(input.copy(baselineEpochSeconds = noReset - "hrv")), hrv = null)
    }

    @Test fun hrvOnlyResetPreservesEligibleRecoverySignalsButNeverOldHrv() {
        val epochs = noReset + ("hrv" to epoch(LocalDate.parse(day).minusDays(1).toString()))
        val input = illnessInput(epochs = epochs)
        assertEquals(1, input.baselinesBefore.getValue("hrv").nValid)
        assertEquals(BaselineStatus.CALIBRATING, input.baselinesBefore.getValue("hrv").status)
        val result = ContextMetricOrchestrator.evaluate(input)
        assertSignals(result, hrv = null)
        assertTrue(result.gaps.contains("illness_baseline_learning"))
    }

    @Test fun recoveryOnlyResetPreservesEligibleHrvButNotOldRecoveryOrSkinDeviation() {
        val epochs = noReset.mapValues { (key, value) -> if (key == "hrv") value else epoch(LocalDate.parse(day).minusDays(1).toString()) }
        val input = illnessInput(epochs = epochs)
        assertTrue(input.baselinesBefore.getValue("hrv").trusted)
        assertTrue(input.baselinesBefore.filterKeys { it != "hrv" }.values.all { it.status == BaselineStatus.CALIBRATING })
        assertSignals(ContextMetricOrchestrator.evaluate(input), rhr = null, resp = null, skin = null)
    }

    @Test fun allResetStatesRemainLearningUntilEligibleSeparatedBaselineExists() {
        val input = illnessInput(epochs = noReset.mapValues { epoch(day) })
        assertTrue(input.baselinesBefore.values.all { it.nValid == 0 && it.status == BaselineStatus.CALIBRATING })
        assertUnavailable(ContextMetricOrchestrator.evaluate(input), "illness_baseline_learning")
    }

    @Test fun resetUsesUtcDayStartAndFractionalBoundaryWithoutChangingDisplayTimezone() {
        val resetDay = LocalDate.parse(day).minusDays(16).toString()
        val boundary = epoch(resetDay)
        for (zone in listOf("UTC", "America/Los_Angeles", "Pacific/Kiritimati")) {
            val exact = illnessInput(epochs = noReset.mapValues { boundary }).copy(timezone = zone)
            assertTrue(exact.baselinesBefore.values.all { it.trusted })
            assertSignals(ContextMetricOrchestrator.evaluate(exact)) // D-16 through D-3 = 14 eligible baseline nights.
            val after = illnessInput(epochs = noReset.mapValues { boundary + .5 }).copy(timezone = zone)
            assertTrue(after.baselinesBefore.values.all { it.trusted })
            assertUnavailable(ContextMetricOrchestrator.evaluate(after), "illness_baseline_learning") // Only 13 separated nights.
        }
    }

    @Test fun preResetValuesCannotContaminateRelearnedSeparatedBaseline() {
        val resetDay = LocalDate.parse(day).minusDays(20).toString()
        val epochs = noReset.mapValues { epoch(resetDay) }
        val poisoned = history().map { row -> if (row.day >= resetDay) row else row.copy(daily = row.daily.copy(
            restingHr = 100, avgHrv = 140.0, respRateBpm = 30.0, skinTempC = 39.0, skinTempDevC = 9.0)) }
        val input = illnessInput(poisoned, epochs)
        assertTrue(input.baselinesBefore.values.all { it.trusted })
        assertSignals(ContextMetricOrchestrator.evaluate(input))
        val trimmed = illnessInput(poisoned.filter { it.day >= resetDay }, epochs)
        assertEquals(trimmed.baselinesBefore, input.baselinesBefore)
        assertTrue(ContextMetricOrchestrator.evaluate(trimmed).metrics.similar(ContextMetricOrchestrator.evaluate(input).metrics))
    }

    @Test fun checkpointRestartAndReplayFeedIdenticalEligibleSignalsAcrossEachReset() {
        fun inputs(date: String, config: JSONObject): SignalSampleReader.DayInputs {
            val bounds = UserDayBounds.forDay(date, ZoneOffset.UTC)
            return SignalSampleReader.DayInputs(UUID.fromString("10000000-0000-4000-8000-000000000001"), date, source,
                bounds.tzOffsetSeconds, bounds.dayLo, bounds.dayHi, UserProfile(), bounds.nightLo, bounds.nightHi,
                emptyList(), emptyList(), emptyList(), emptyList(), emptyList(), DeviceFamily.WHOOP5, "UTC",
                HistoryInputReader.Day(listOf(HistoryInputReader.Input("config", "primary", 1, false, config),
                    HistoryInputReader.Input("context", "today", 1, false, JSONObject().put("day", date).put("flags", JSONObject(allNo))))))
        }
        fun result(row: HistoricalDailyObservation) = DayResult(row.daily, emptyList(), emptyList(), null, null, nightlySkinTempC = row.daily.skinTempC)
        val rows = history()
        val commits = mutableListOf<HistoricalStateMachine.Commit>()
        for (row in rows.dropLast(2)) {
            val input = inputs(row.day, JSONObject())
            val prepared = HistoricalStateMachine.prepare(input, HistoryCheckpointReader.Seed(commits.lastOrNull()?.state,
                commits.map { it.state.getJSONObject("observation") }))
            commits += HistoricalStateMachine.finish(input, result(row), prepared, emptyMap())
        }
        for (reset in listOf("hrvBaselineEpoch", "recoveryBaselineEpoch")) {
            val yesterday = rows[rows.lastIndex - 1]
            val config = JSONObject().put("journalContextEnabled", true).put(reset, epoch(yesterday.day))
            val observations = commits.map { it.state.getJSONObject("observation") }
            val resetInput = inputs(yesterday.day, config)
            val resetPrepared = HistoricalStateMachine.prepare(resetInput, HistoryCheckpointReader.Seed(commits.last().state, observations))
            val saved = HistoricalStateMachine.finish(resetInput, result(yesterday), resetPrepared, emptyMap()).state
            val reopened = JSONObject(saved.toString()) // No retained in-memory state across this boundary.
            val allRows = (observations + reopened.getJSONObject("observation")).map { JSONObject(it.toString()) }
            val today = inputs(day, config)
            val resumed = HistoricalStateMachine.prepare(today, HistoryCheckpointReader.Seed(reopened, allRows))
            val replayed = HistoricalStateMachine.prepare(today, HistoryCheckpointReader.Seed(null, allRows))
            assertEquals(resumed.baselines, replayed.baselines)
            val a = ContextMetricOrchestrator.evaluate(HistoricalContextInputFactory.build(today, result(rows.last()), resumed))
            val b = ContextMetricOrchestrator.evaluate(HistoricalContextInputFactory.build(today, result(rows.last()), replayed))
            assertTrue(a.metrics.similar(b.metrics)); assertTrue(a.details.similar(b.details)); assertEquals(a.gaps, b.gaps)
            if (reset == "hrvBaselineEpoch") assertSignals(a, hrv = null)
            else assertSignals(a, rhr = null, resp = null, skin = null)
        }
    }

    @Test fun futureDailyRawPeriodAndHourlyInputsCannotChangeHistoricalOutput() {
        val input = illnessInput()
        val before = ContextMetricOrchestrator.evaluate(input)
        val future = LocalDate.parse(day).plusDays(1)
        val ts = future.atStartOfDay(ZoneId.of("UTC")).toEpochSecond()
        val polluted = input.copy(history = input.history + HistoricalDailyObservation(future.toString(),
            DailyMetric(source, future.toString(), restingHr = 120, avgHrv = 200.0, skinTempC = 41.0)),
            hr = List(1000) { HrSample(source, ts + it, 240) },
            rr = List(1000) { RrInterval(source, ts + it, 800 + it % 2 * 40) },
            hourlyHr = listOf(HistoricalHourlyObservation(ts, 240.0, 3600)), periodStarts = listOf(future.toString()))
        val after = ContextMetricOrchestrator.evaluate(polluted)
        assertTrue(before.metrics.similar(after.metrics)); assertTrue(before.charts.similar(after.charts))
        assertTrue(before.details.similar(after.details)); assertEquals(before.gaps, after.gaps)
        assertEquals(before.baselineObservations, after.baselineObservations)
    }

    @Test fun cycleUsesEachNightsPreObservationStatesAndExcludesFuturePeriodAnchors() {
        val states = mapOf("skin_temp" to state(35.0, .3), "resting_hr" to state(55.0, 2.0), "hrv" to state(55.0, 5.0))
        val rows = (0 until 60).map { i ->
            val date = LocalDate.parse(day).minusDays((59 - i).toLong()).toString()
            val wave = sin(2 * PI * i / 28)
            HistoricalDailyObservation(date, DailyMetric(source, date, skinTempC = 35 + .5 * wave,
                restingHr = 55 + (3 * wave).toInt(), avgHrv = 55 - 8 * wave), states)
        }
        val periods = listOf("2026-08-01", "2026-08-29", "2026-12-01")
        val input = empty().copy(history = rows, baselinesBefore = states, cycleEnabled = true, periodStarts = periods,
            baselineEpochSeconds = noReset)
        val result = ContextMetricOrchestrator.evaluate(input)
        val nights = rows.map { r -> CyclePhaseEngine.Night(r.day,
            Baselines.deviation(r.daily.skinTempC!!, states.getValue("skin_temp")).z,
            Baselines.deviation(r.daily.restingHr!!.toDouble(), states.getValue("resting_hr")).z,
            Baselines.deviation(r.daily.avgHrv!!, states.getValue("hrv")).z) }
        val expected = CyclePhaseEngine.classify(nights, true, periods.filter { it <= day })
        assertEquals(expected.phase.raw, result.details.getJSONObject("cycle").getString("phase"))
        assertEquals(60, result.charts.getJSONArray("cycle_index").length())
        val noConsent = ContextMetricOrchestrator.evaluate(input.copy(cycleEnabled = false))
        assertTrue(noConsent.details.isNull("cycle")); assertFalse(noConsent.charts.has("cycle_index"))
        val cold = ContextMetricOrchestrator.evaluate(input.copy(history = rows.takeLast(3)))
        assertEquals("learning", cold.details.getJSONObject("cycle").getString("phase"))
    }

    @Test fun circadianUsesObservedLocalHourProxyNotFabricatedTemperatureOrWake() {
        val zone = ZoneId.of("America/Los_Angeles")
        val date = LocalDate.parse("2026-11-04")
        val hours = (0L..13L).flatMap { back -> (0..23).map { hour ->
            val start = date.minusDays(back).atTime(hour, 0).atZone(zone).toEpochSecond()
            HistoricalHourlyObservation(start, 65 + 10 * cos(2 * PI * (hour - 16) / 24), 100)
        }}
        val input = empty().copy(day = date.toString(), timezone = zone.id, hourlyHr = hours)
        val result = ContextMetricOrchestrator.evaluate(input)
        val expected = CircadianEngine.estimatePhase((0..23).map { CircadianEngine.ActivityBin(it.toDouble(), 65 + 10 * cos(2 * PI * (it - 16) / 24)) }, 14, 7.0)!!
        assertEquals(expected.tempMinHour, result.metrics.getJSONObject("circadian_phase_hour").getDouble("value"), 1e-12)
        assertTrue(result.metrics.getJSONObject("circadian_offset_min").isNull("value"))
        assertFalse(result.details.getJSONObject("circadian").getBoolean("measuredTemperatureMinimum"))
        assertEquals(14, result.details.getJSONObject("circadian").getInt("observedDays"))
    }

    @Test fun daytimeUsesExistingMathAndPersonalBaselineRequiresConfigurationOptIn() {
        val lo = LocalDate.parse(day).atStartOfDay(ZoneId.of("UTC")).toEpochSecond()
        val hr = listOf(60, 75, 100).flatMapIndexed { index, bpm -> (0L until 300L).map { HrSample(source, lo + (8 + index) * 3600 + it, bpm) } }
        val rr = hr.mapIndexed { index, sample -> RrInterval(source, sample.ts, 800 + index % 2 * 40) }
        val input = empty().copy(hr = hr, rr = rr, baselinesBefore = mapOf("daytime_hr" to state(50.0, 3.0)))
        val default = ContextMetricOrchestrator.evaluate(input)
        val expected = DaytimeStress.analyze(hr, rr)
        assertEquals(expected.dayMean!!, default.metrics.getJSONObject("daytime_stress_mean").getDouble("value"), 1e-12)
        assertFalse(default.details.getJSONObject("daytimeStress").getBoolean("personalBaseline"))
        assertFalse("daily stress hero and hourly stress mean are different contracts", default.metrics.has("stress"))
        val enabled = ContextMetricOrchestrator.evaluate(input, daytimePersonalBaselineEnabled = true)
        assertTrue(enabled.details.getJSONObject("daytimeStress").getBoolean("personalBaseline"))
        val aggregate = DaytimeBaselines.dayDaytimeAggregate(hr, rr, 0)
        assertEquals(aggregate.hr, enabled.baselineObservations["daytime_hr"])
        assertEquals(StressIndex.stressIndex(rr)!!, enabled.metrics.getJSONObject("baevsky_stress_index").getDouble("value"), 1e-12)
    }

    @Test fun mixedOrDuplicatedHistoricalSourceFailsInsteadOfBlending() {
        val rows = history()
        for (invalid in listOf(rows + rows.last(), rows.dropLast(1) + rows.last().copy(daily = rows.last().daily.copy(deviceId = "other")))) {
            try { ContextMetricOrchestrator.evaluate(empty().copy(history = invalid)); fail("invalid source grain accepted") }
            catch (_: IllegalArgumentException) {}
        }
    }
}
