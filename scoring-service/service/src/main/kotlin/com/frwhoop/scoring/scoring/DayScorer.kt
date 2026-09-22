package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.DayResult
import com.noop.analytics.DetectedSleep
import com.noop.analytics.SleepStager
import com.noop.analytics.StrainScorer
import com.noop.protocol.DeviceFamily

/**
 * Runs the existing Kotlin kernel with source-local, strictly prior-day historical state.
 */
class DayScorer {
    fun score(inputs: SignalSampleReader.DayInputs, algorithmVersion: String,
              history: HistoricalStateMachine.Prepared? = null): ServerScoreBundle {
        // Local-day bounds (from the user's profile timezone via UserDayBounds) — the SAME local-day
        // semantics queue discovery uses. UTC-midnight bounds would shift the scored window for any
        // non-UTC user (Phase 3 gate failure: "DayScorer currently uses a UTC day boundary").
        val dayLo = inputs.dayLo
        val dayHi = inputs.dayHi
        val dayHr = AnalyticsEngine.daySliceFromNight(
            inputs.hr, inputs.nightLo, inputs.nightHi, dayLo, dayHi,
        ) { it.ts } ?: inputs.hr.filter { it.ts in dayLo..dayHi }
        val dayGravity = AnalyticsEngine.daySliceFromNight(
            inputs.gravity, inputs.nightLo, inputs.nightHi, dayLo, dayHi,
        ) { it.ts } ?: inputs.gravity.filter { it.ts in dayLo..dayHi }

        val wristOff = AnalyticsEngine.offWristIntervals(inputs.events, inputs.nightHi)

        val configuration = inputs.history.configuration
        fun optionalNumber(key: String): Double? = if (configuration.isNull(key)) null else configuration.getDouble(key)
        val useV2 = configuration.optBoolean("useSleepStagerV2",true)
        val hrOnly = if (inputs.gravity.isEmpty()) SleepStager.hrOnlySessions(inputs.hr,inputs.rr,inputs.scoringResp) else emptyList()
        fun analyze(resolved: List<DetectedSleep>? = null, excludedMain: Set<Long> = emptySet()) = AnalyticsEngine.analyzeDay(
            day = inputs.day,
            hr = inputs.hr,
            rr = inputs.rr,
            resp = inputs.scoringResp,
            vendorResp = inputs.vendorResp,
            gravity = inputs.gravity,
            steps = inputs.steps,
            daySteps = inputs.steps.filter { it.ts in dayLo..dayHi },
            skinTemp = inputs.skinTemp,
            spo2 = inputs.spo2,
            bandSleepState = inputs.bandSleepState,
            dayHr = dayHr,
            dayGravity = dayGravity,
            profile = inputs.profile,
            baselines = history?.profileBaselines ?: com.noop.analytics.ProfileBaselines(),
            tzOffsetSeconds = inputs.tzOffsetSeconds,
            wristOff = wristOff,
            skinTempFamily = inputs.deviceFamily,
            skinTempAnchorRaw = history?.skinTempAnchorRaw,
            skinTempWornToleranceSec = if(inputs.isOura) AnalyticsEngine.DEFAULT_OURA_WORN_TOLERANCE_SEC else 0,
            useSleepStagerV2 = useV2,
            useMotionAwareWake = configuration.optBoolean("useMotionAwareWake",inputs.deviceFamily != DeviceFamily.WHOOP4),
            maxHROverride = optionalNumber("maxHR"),
            sleepNeedHours = history?.needHours ?: optionalNumber("sleepNeedHours"),
            sleepConsistency = history?.consistency,
            habitualMidsleepSec = history?.habitualMidsleep,
            deepHrvWindow = configuration.optBoolean("deepHrvWindow",false),
            effortMethod = StrainScorer.Method.valueOf(configuration.optString("effortMethod","EDWARDS")),
            providedSleep = hrOnly,
            resolvedSleep = resolved,
            excludedMainSleepStarts = excludedMain,
            localDayBounds = dayLo to dayHi+1,
            timezone = java.time.ZoneId.of(inputs.timezone),
        )
        val detected = analyze()
        val edited = inputs.history.sleepEdits.takeIf { it.isNotEmpty() }?.let {
            SleepEditResolver.resolve(detected.sleepSessions,inputs,useV2)
        }
        val scored = if (edited == null) detected else analyze(edited.sessions,
            edited.naps.filterValues { it }.keys.map { it.start }.toSet())
        val cycle=history?.let { DayCycleMetricOrchestrator.evaluate(inputs,scored,it,edited?.identities ?: emptyMap(),edited?.naps ?: emptyMap()) }
        val additive=cycle?.scored ?: scored
        val imported=ImportedMetricResolver.resolve(inputs)
        val acceptsCalendarImport=cycle?.usesCalendar != false
        val workoutCount=WorkoutResultOrchestrator.evaluate(inputs,additive,cycle).count
        val result=additive.copy(daily=additive.daily.copy(deviceId=inputs.deviceId,
            steps=imported["steps_count"]?.takeIf { acceptsCalendarImport }?.value?.toInt() ?: additive.daily.steps,
            activeKcalEst=imported["active_energy_kcal"]?.takeIf { acceptsCalendarImport }?.value ?: additive.daily.activeKcalEst,
            exerciseCount=workoutCount,
            spo2Pct=imported["spo2_pct"]?.value ?: additive.daily.spo2Pct))
        val context=history?.let {
            val input=HistoricalContextInputFactory.build(inputs,result,it,edited?.naps ?: emptyMap())
            ContextMetricOrchestrator.evaluate(input,daytimePersonalBaselineEnabled=input.daytimePersonalBaselineEnabled)
        }
        val historyCommit=history?.let { HistoricalStateMachine.finish(inputs,result,it,edited?.naps ?: emptyMap(),context?.baselineObservations ?: emptyMap()) }
        if(cycle!=null) historyCommit?.state?.getJSONObject("observation")?.put("dayCycle",cycle.details(inputs.day))
        val derived=historyCommit?.let { ServerMetricOrchestrator.evaluate(inputs,result,it,edited?.identities ?: emptyMap(),edited?.naps ?: emptyMap(),cycle)
            .withContext(requireNotNull(context)) }
        val contextGaps = buildList {
            val context = inputs.history.values.firstOrNull { it.kind=="context" && !it.deleted && it.payload.optString("day")==inputs.day }
            if (!configuration.optBoolean("journalContextEnabled",false)) add("journal_context_not_shared")
            else if (context == null || context.payload.getJSONObject("flags").keySet().any { context.payload.getJSONObject("flags").isNull(it) })
                add("journal_context_incomplete")
            if (!configuration.optBoolean("cycleAwarenessEnabled",false)) add("cycle_context_not_shared")
            else if (inputs.history.values.none { it.kind=="period" && !it.deleted }) add("period_history_unavailable")
            if (inputs.history.values.none { it.kind=="imported_daily" && !it.deleted }) add("imported_source_unavailable")
            if (inputs.legacyWorkouts.isEmpty() && inputs.history.values.none { it.kind=="manual_workout" && !it.deleted }) add("manual_workout_history_unavailable")
        }

        return ServerScoreBundle(
            userId = inputs.userId,
            day = inputs.day,
            deviceId = inputs.deviceId,
            algorithmVersion = algorithmVersion,
            result = result,
            timezone = inputs.timezone,
            tzOffsetSeconds = inputs.tzOffsetSeconds,
            dataThrough = listOfNotNull(inputs.hr.maxOfOrNull { it.ts }, inputs.rr.maxOfOrNull { it.ts },
                inputs.resp.maxOfOrNull { it.ts }, inputs.gravity.maxOfOrNull { it.ts },
                inputs.events.maxOfOrNull { it.ts },inputs.steps.maxOfOrNull { it.ts },inputs.skinTemp.maxOfOrNull { it.ts },
                inputs.spo2.maxOfOrNull { it.ts },inputs.bandSleepState.maxOfOrNull { it.first },
                inputs.scalarInputs?.ppgHr?.maxOfOrNull { it.ts }).maxOrNull(),
            hrSamples = inputs.hr.size,
            rrIntervals = inputs.rr.size,
            sleepIdentities = edited?.identities ?: emptyMap(),
            sleepNapOverrides = edited?.naps ?: emptyMap(),
            historyCommit = historyCommit,
            derived = derived,
            hasNonRawObservations = imported.isNotEmpty() || (workoutCount ?: 0)>0,
            coverageGaps = (if(history == null) listOf("historical_baselines_unavailable") else emptyList()) +
                inputs.auxiliaryGaps + (inputs.scalarInputs?.gaps ?: emptySet()) +
                (if (inputs.history.profile == null) listOf("profile_history_unavailable") else emptyList()) +
                (if (inputs.history.config == null) listOf("sleep_preferences_unavailable") else emptyList()) +
                (edited?.gaps ?: emptyList()) + contextGaps + (derived?.gaps ?: emptySet()),
        )
    }
}

data class ServerScoreBundle(
    val userId: java.util.UUID,
    val day: String,
    val deviceId: String,
    val algorithmVersion: String,
    val result: DayResult,
    val timezone: String = "UTC",
    val tzOffsetSeconds: Long = 0,
    val dataThrough: Long? = null,
    val hrSamples: Int = 0,
    val rrIntervals: Int = 0,
    val sleepIdentities: Map<SleepBounds, SleepIdentity> = emptyMap(),
    val sleepNapOverrides: Map<SleepBounds, Boolean> = emptyMap(),
    val historyCommit: HistoricalStateMachine.Commit? = null,
    val derived: ServerDerivedMetrics? = null,
    val hasNonRawObservations: Boolean = false,
    val coverageGaps: List<String> = listOf(
        "historical_baselines_unavailable", "sleep_preferences_unavailable", "sleep_edits_unavailable",
        "hr_only_fallback_not_integrated", "kernel_fixed_offset_day_policy", "additional_streams_not_integrated",
    ),
)
