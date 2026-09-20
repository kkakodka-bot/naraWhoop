package com.frwhoop.scoring.scoring

import com.noop.analytics.*
import com.noop.data.DailyMetric
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset

/** Existing context engines, with caller-owned historical inputs and no clock, IO or notifications. */
object ContextMetricOrchestrator {
    private val flagNames = setOf("alcohol", "stress", "sauna", "hardOrLateWorkout", "travelPhaseJump", "alreadyUnwell")

    fun evaluate(input: HistoricalContextInputs,
                 daytimePersonalBaselineEnabled: Boolean = input.daytimePersonalBaselineEnabled): HistoricalContextResult {
        val day = LocalDate.parse(input.day)
        val zone = ZoneId.of(input.timezone)
        val lo = day.atStartOfDay(zone).toEpochSecond()
        val hi = day.plusDays(1).atStartOfDay(zone).toEpochSecond()
        val history = input.history.filter { it.day <= input.day && it.daily.day == it.day }
            .sortedBy { it.day }
        require(history.map { it.day }.distinct().size == history.size) { "duplicate_context_day" }
        require(history.map { it.daily.deviceId }.distinct().size <= 1) { "mixed_context_source" }
        val metrics = JSONObject()
        val charts = JSONObject()
        val details = JSONObject().put("contextPolicy", "as-of-context-v1")
        val gaps = linkedSetOf<String>()
        val capabilities = linkedSetOf<String>()

        fun reading(key: String, value: Number?, unit: String, method: String) {
            val finite = value?.toDouble()?.takeIf { it.isFinite() }
            metrics.put(key, JSONObject().put("value", finite ?: JSONObject.NULL)
                .put("unit", unit).put("method", method))
        }

        // Preserve the two-day mean and separated 28-day baseline, without compressing missing days.
        // Missing confounders cannot be sent to an engine whose Boolean defaults mean observed "no".
        val byDay = history.associateBy { it.day }
        val current = byDay[input.day]?.daily
        fun skinDeviation(d: DailyMetric): Double? = d.skinTempDevC?.takeIf { it.isFinite() && it in -10.0..10.0 }
        val hasCurrent = current != null && listOf(current.restingHr?.toDouble(), current.avgHrv,
            current.respRateBpm, skinDeviation(current)).any { it?.isFinite() == true }
        val knownContext = input.journalEnabled && flagNames.all { input.contextFlags[it] != null }
        if (!input.journalEnabled) gaps += "journal_context_not_shared"
        else if (!knownContext) gaps += "journal_context_incomplete"
        var illness: IllnessSignalEngine.Result? = null
        var distance: IllnessDistance.Result? = null
        if (knownContext && hasCurrent) {
            val recentDays = listOf(day.minusDays(1), day)
            val baseDays = List(28) { day.minusDays(30L - it) }
            data class Signal(val reading: IllnessSignalEngine.SignalReading, val trusted: Boolean, val hasCurrent: Boolean)
            fun eligibleEpoch(key: String): Double? {
                // An omitted policy is unknown, not permission to resurrect pre-reset observations.
                val epoch = input.baselineEpochSeconds[key]?.takeIf { it.isFinite() && it >= 0.0 }
                if (epoch == null) {
                    gaps += "illness_reset_policy_unavailable"
                    return null
                }
                val before = input.baselinesBefore[key]
                if (before?.usable != true) {
                    gaps += if (before?.status == BaselineStatus.STALE) "illness_baseline_stale" else "illness_baseline_learning"
                    return null
                }
                return epoch
            }
            fun recentValues(epoch: Double, select: (DailyMetric) -> Double?): List<Pair<LocalDate, Double>> =
                recentDays.mapNotNull { date ->
                    // Same day-key rule as the checkpoint fold, not the current display timezone.
                    if (date.atStartOfDay(ZoneOffset.UTC).toEpochSecond() < epoch) null
                    else byDay[date.toString()]?.daily?.let(select)?.takeIf { it.isFinite() }?.let { date to it }
                }
            fun signal(key: String, positive: Boolean, select: (DailyMetric) -> Double?): Signal? {
                val epoch = eligibleEpoch(key) ?: return null
                val values = recentValues(epoch, select)
                if (values.isEmpty()) return null
                val baseline = Baselines.foldHistory(
                    baseDays.map { byDay[it.toString()]?.daily?.let(select)?.takeIf { value -> value.isFinite() } },
                    baseDays.map { it.toString() }, Baselines.metricCfg.getValue(key), epoch)
                if (!baseline.usable) {
                    gaps += if (baseline.status == BaselineStatus.STALE) "illness_baseline_stale" else "illness_baseline_learning"
                    return null
                }
                val z = Baselines.deviation(values.map { it.second }.average(), baseline).z * if (positive) 1 else -1
                return Signal(IllnessSignalEngine.SignalReading(z),
                    baseline.trusted && input.baselinesBefore.getValue(key).trusted, values.any { it.first == day })
            }
            val rhr = signal("resting_hr", true) { it.restingHr?.toDouble() }
            val hrv = signal("hrv", false) { it.avgHrv }
            val resp = signal("resp", true) { it.respRateBpm }
            // This schema field is a deviation, never an imported absolute temperature.
            val skinValues = eligibleEpoch("skin_temp")?.let { recentValues(it, ::skinDeviation) }.orEmpty()
            val skin = skinValues.takeIf { it.isNotEmpty() }?.let { values ->
                Signal(IllnessSignalEngine.SignalReading(values.map { it.second }.average() / 0.3),
                    false, values.any { it.first == day })
            }
            val trusted = rhr?.trusted == true || hrv?.trusted == true
            val hasEligibleCurrent = listOfNotNull(rhr, hrv, resp, skin).any { it.hasCurrent }
            if (trusted && hasEligibleCurrent) {
                val flags = input.contextFlags
                illness = IllnessSignalEngine.evaluate(
                    IllnessSignalEngine.Inputs(rhr?.reading, skin?.reading, hrv?.reading, resp?.reading),
                    IllnessSignalEngine.Context(flags.getValue("alcohol")!!, flags.getValue("stress")!!,
                        flags.getValue("sauna")!!, flags.getValue("hardOrLateWorkout")!!,
                        flags.getValue("travelPhaseJump")!!, flags.getValue("alreadyUnwell")!!, true),
                )
                distance = IllnessDistance.evaluate(IllnessDistance.FeatureVector(rhr?.reading?.zIllnessward,
                    hrv?.reading?.zIllnessward, skin?.reading?.zIllnessward, resp?.reading?.zIllnessward))
                capabilities += listOf("illness_score", "illness_distance")
            } else {
                if (!trusted) gaps += "illness_baseline_learning"
                if (!hasEligibleCurrent) gaps += "current_day_physiology_unavailable"
            }
        } else if (knownContext) gaps += if (!hasCurrent) "current_day_physiology_unavailable" else "illness_baseline_learning"
        reading("illness_score", illness?.score, "score_0_100", "IllnessSignalEngine")
        reading("illness_distance", distance?.distance, "dimensionless", "IllnessDistance_identity_correlation")
        details.put("illness", illness?.let {
            val distanceResult = requireNotNull(distance)
            JSONObject().put("level", it.level.raw).put("signalCount", it.signalCount)
                .put("firedSignals", JSONArray(it.firedSignals)).put("copy", it.copy)
                .put("suppressedBy", JSONArray(it.suppressedBy)).put("distanceFires", distanceResult.fires)
                .put("distanceDeviatingFeatures", distanceResult.deviatingFeatures)
                .put("distanceUsedDiagonalFallback", distanceResult.usedDiagonalFallback)
                .put("distanceIsAlertGate", false).put("wellnessOnly", true)
        } ?: JSONObject.NULL)

        // Each night uses its own pre-observation baseline, never the end-of-history baseline.
        // Absolute temperature and named deviation remain separate; no bimodal column conversion.
        if (!input.cycleEnabled) {
            gaps += "cycle_context_not_shared"
            details.put("cycle", JSONObject.NULL)
        } else {
            fun z(value: Double?, key: String, states: Map<String, BaselineState>): Double? {
                val state = states[key]?.takeIf { it.usable } ?: return null
                return value?.takeIf { it.isFinite() }?.let { Baselines.deviation(it, state).z }
            }
            val observedNights = history.map { observation ->
                val d = observation.daily
                CyclePhaseEngine.Night(observation.day,
                    z(d.skinTempC, "skin_temp", observation.baselinesBefore),
                    z(d.restingHr?.toDouble(), "resting_hr", observation.baselinesBefore),
                    z(d.avgHrv, "hrv", observation.baselinesBefore))
            }
            val cycleKeys = setOf("skin_temp", "resting_hr", "hrv")
            if (cycleKeys.any { input.baselineEpochSeconds[it]?.let { epoch -> epoch.isFinite() && epoch >= 0 } != true })
                gaps += "cycle_reset_policy_unavailable"
            // Keep the immutable chart series above. Today's classifier may use only features
            // admitted by today's independent epochs, still standardized against each night's own state.
            val nights = observedNights.map { night ->
                fun eligible(key: String) = HistoricalMetricAdmission.eligible(night.day, key,
                    input.baselineEpochSeconds, input.baselinesBefore)
                night.copy(tempZ = night.tempZ.takeIf { eligible("skin_temp") },
                    rhrZ = night.rhrZ.takeIf { eligible("resting_hr") },
                    hrvZ = night.hrvZ.takeIf { eligible("hrv") })
            }
            val periods = input.periodStarts.filter { it <= input.day && runCatching { LocalDate.parse(it) }.isSuccess }.distinct().sorted()
            if (periods.isEmpty()) gaps += "period_history_unavailable"
            val usable = input.baselinesBefore["skin_temp"]?.usable == true && nights.any { it.tempZ != null }
            if (!usable) gaps += "cycle_temperature_baseline_unavailable"
            val currentNight = nights.singleOrNull { it.day == input.day }
            val hasCurrentCycle = currentNight?.let { CyclePhaseEngine.fusedIndex(it.tempZ, it.rhrZ, it.hrvZ) } != null
            if (!hasCurrentCycle) gaps += "cycle_current_physiology_unavailable"
            else if (currentNight?.tempZ == null) gaps += "cycle_current_temperature_unavailable"
            val result = CyclePhaseEngine.classifyCalendar(nights, usable && hasCurrentCycle, input.day, periods)
            if (result.phase == CyclePhaseEngine.Phase.LEARNING) gaps += "cycle_history_learning"
            capabilities += "cycle_phase"
            details.put("cycle", JSONObject().put("phase", result.phase.raw).put("confidence", result.confidence.raw)
                .put("note", result.note)
                .put("cycleDayLow", result.cycleDayLow ?: JSONObject.NULL).put("cycleDayHigh", result.cycleDayHigh ?: JSONObject.NULL)
                .put("cycleLengthDays", result.cycleLengthDays ?: JSONObject.NULL)
                .put("nextPeriodWindow", result.nextPeriodWindow?.let {
                    JSONObject().put("earliestDay", it.earliestDay).put("latestDay", it.latestDay)
                } ?: JSONObject.NULL).put("shiftMarkers", JSONArray(result.shiftMarkers.map { it.day }))
                .put("awarenessOnly", true).put("baselinePolicy", "pre_observation_absolute_temperature"))
            charts.put("cycle_index", JSONArray(observedNights.mapNotNull { night ->
                val value = CyclePhaseEngine.fusedIndex(night.tempZ, night.rhrZ, night.hrvZ) ?: return@mapNotNull null
                val date = LocalDate.parse(night.day)
                JSONObject().put("start", date.atStartOfDay(zone).toEpochSecond())
                    .put("end", date.plusDays(1).atStartOfDay(zone).toEpochSecond()).put("value", value)
            }))
        }

        // Pool observed hourly means like the existing app, but resolve the offset at EACH instant.
        val from = day.minusDays(13).atStartOfDay(zone).toEpochSecond()
        val hourly = input.hourlyHr.filter { it.start in from until hi && it.meanHr.isFinite() && it.meanHr > 0 && it.sampleCount > 0 }
        val groups = hourly.groupBy { Instant.ofEpochSecond(it.start).atZone(zone).hour }
        val bins = groups.toSortedMap().map { (hour, values) -> CircadianEngine.ActivityBin(hour.toDouble(), values.map { it.meanHr }.average()) }
        val observedDays = hourly.map { Instant.ofEpochSecond(it.start).atZone(zone).toLocalDate() }.distinct().size
        val lastWake = input.sleepBounds.filter { it.start < it.end && it.end in from until hi }.maxOfOrNull { it.end }
        val wakeHour = lastWake?.let { Instant.ofEpochSecond(it).atZone(zone).toLocalTime().toSecondOfDay() / 3600.0 }
        val phase = if (hourly.size >= 24 && bins.size >= 6) CircadianEngine.estimatePhase(bins, observedDays, wakeHour ?: 7.0) else null
        if (phase == null) gaps += "circadian_hourly_history_unavailable"
        else if (phase.confidence == CircadianEngine.PhaseConfidence.UNREADABLE) gaps += "circadian_rhythm_unreadable"
        if (wakeHour == null) gaps += "sleep_schedule_unavailable"
        val readablePhase = phase?.takeUnless { it.confidence == CircadianEngine.PhaseConfidence.UNREADABLE }
        reading("circadian_phase_hour", readablePhase?.tempMinHour, "local_hour", "CircadianEngine_observed_hourly_hr_proxy")
        reading("circadian_offset_min", readablePhase?.offsetVsScheduleMinutes?.takeIf { wakeHour != null }, "min", "CircadianEngine")
        details.put("circadian", phase?.let {
            JSONObject().put("confidence", it.confidence.raw).put("acrophaseHours", it.acrophaseHours)
                .put("note", it.note)
                .put("observedDays", observedDays).put("habitualWakeHour", wakeHour ?: JSONObject.NULL)
                .put("measuredTemperatureMinimum", false)
        } ?: JSONObject.NULL)
        if (readablePhase != null) capabilities += "circadian_phase_hour"
        if (readablePhase != null && wakeHour != null) capabilities += "circadian_offset_min"

        val hr = input.hr.filter { it.ts in lo until hi && it.bpm in 20..250 }.sortedBy { it.ts }
        val rr = input.rr.filter { it.ts in lo until hi }.sortedWith(compareBy({ it.ts }, { it.ord }))
        val gravity = input.gravity.filter { it.ts in lo until hi }.sortedBy { it.ts }
        val daytimeBaseline = input.baselinesBefore["daytime_hr"]?.takeIf { it.usable }
        val mode = if (daytimePersonalBaselineEnabled && daytimeBaseline != null) {
            val rmssd = input.baselinesBefore["daytime_rmssd"]?.takeIf { it.usable && DaytimeStress.daytimeRMSSDScoringEnabled }
            DaytimeStress.ScoringMode.BaselineRelative(daytimeBaseline, rmssd)
        } else DaytimeStress.ScoringMode.DayRelative
        // The timezone-aware overload is additive; existing Android callers retain the fixed-offset API.
        val stress = DaytimeStress.analyze(hr, rr, gravity, mode = mode, timezone = zone)
        val aggregate = DaytimeBaselines.dayDaytimeAggregate(hr, rr, 0L, timezone = zone)
        val baevsky = StressIndex.components(rr)
        val frequency = HrvFreqDomain.freqDomain(rr)
        reading("daytime_stress_mean", stress.dayMean, "score_0_3", "DaytimeStress")
        reading("daytime_stress_high_min", stress.highStressMinutes.takeIf { stress.scored.isNotEmpty() }, "min", "DaytimeStress_hourly_approximation")
        reading("baevsky_stress_index", baevsky?.si, "dimensionless", "StressIndex")
        if (stress.scored.isEmpty()) gaps += "daytime_stress_insufficient_data"
        else capabilities += listOf("daytime_stress_mean", "daytime_stress_high_min")
        if (baevsky != null) capabilities += "baevsky_stress_index"
        charts.put("daytime_stress", JSONArray(stress.hours.map {
            JSONObject().put("start", it.startTs).put("end", minOf(hi, it.startTs + DaytimeStress.bucketSeconds))
                .put("value", it.level ?: JSONObject.NULL).put("meanHr", it.meanHr ?: JSONObject.NULL)
                .put("rmssd", it.rmssd ?: JSONObject.NULL).put("maskedForActivity", it.maskedForActivity)
        }))
        details.put("daytimeStress", JSONObject().put("personalBaseline", mode is DaytimeStress.ScoringMode.BaselineRelative)
            .put("hrOnlyFallback", stress.hrOnlyFallback).put("activityMaskedHours", stress.activityMaskedHours)
            .put("sustainedHigh", stress.sustainedHigh.takeIf { stress.scored.isNotEmpty() } ?: JSONObject.NULL)
            .put("sustainedRun", stress.sustainedRun.takeIf { stress.scored.isNotEmpty() } ?: JSONObject.NULL))
        details.put("frequencyHrv", frequency?.let {
            JSONObject().put("lfPower", it.lf ?: JSONObject.NULL).put("hfPower", it.hf).put("lfHfRatio", it.lfhf ?: JSONObject.NULL)
        } ?: JSONObject.NULL)

        return HistoricalContextResult(metrics, charts, details, capabilities, gaps,
            mapOf("daytime_hr" to aggregate.hr, "daytime_rmssd" to aggregate.rmssd))
    }
}
