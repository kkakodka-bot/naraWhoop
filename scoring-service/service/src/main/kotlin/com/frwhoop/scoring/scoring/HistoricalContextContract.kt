package com.frwhoop.scoring.scoring

import com.noop.analytics.BaselineState
import com.noop.data.DailyMetric
import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.json.JSONObject

/** Disjoint helper seam: all observations are owned by ONE canonical source and no later than day. */
data class HistoricalDailyObservation(
    val day: String,
    val daily: DailyMetric,
    val baselinesBefore: Map<String,BaselineState> = emptyMap(),
)

/** Observed hourly HR proxy used by the existing circadian orchestration, not fabricated activity. */
data class HistoricalHourlyObservation(val start: Long, val meanHr: Double, val sampleCount: Int)

data class HistoricalContextInputs(
    val day: String,
    val timezone: String,
    val history: List<HistoricalDailyObservation>,
    val baselinesBefore: Map<String,BaselineState>,
    val hr: List<HrSample>,
    val rr: List<RrInterval>,
    val gravity: List<GravitySample>,
    val sleepBounds: List<SleepBounds>,
    val hourlyHr: List<HistoricalHourlyObservation>,
    val journalEnabled: Boolean,
    val cycleEnabled: Boolean,
    val contextFlags: Map<String,Boolean?>,
    val periodStarts: List<String>,
    val daytimePersonalBaselineEnabled: Boolean = false,
    // A day is eligible for a metric only when its UTC day key starts at/after this epoch.
    // Matches HistoricalStateMachine/Baselines reset policy, independent of display timezone.
    val baselineEpochSeconds: Map<String,Double> = emptyMap(),
)

/** Optional v2 extension vocabulary. Missing prerequisites produce named gaps, never negative facts. */
data class HistoricalContextResult(
    val metrics: JSONObject = JSONObject(),
    val charts: JSONObject = JSONObject(),
    val details: JSONObject = JSONObject(),
    val capabilities: Set<String> = emptySet(),
    val gaps: Set<String> = emptySet(),
    // Pure daytime aggregates to fold into the NEXT checkpoint, not today's pre-observation baseline.
    val baselineObservations: Map<String,Double?> = emptyMap(),
)
