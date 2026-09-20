package com.noop.analytics

/*
 * AnalyticsModels.kt — shared on-device analytics value types.
 *
 * Faithful Kotlin port of the shared model types that the StrandAnalytics Swift
 * package defines and shares across its analyzers:
 *   - StrandAnalytics.swift  → [StrandAnalytics] version marker
 *   - WorkoutDetector.swift  → [UserProfile], [ExerciseSession], [ActivityPoint]
 *   - SleepStager.swift      → [StageSegment], [DetectedSleep], [HypnogramMetrics]
 *   - Baselines.swift        → [MetricCfg], [BaselineStatus], [BaselineState], [Deviation]
 *   - AnalyticsEngine.swift  → [ProfileBaselines], [DayResult]
 *
 * Naming notes (clash avoidance):
 *   - The analytics-internal detected-sleep type is [DetectedSleep] so it does NOT
 *     clash with the Room entity com.noop.data.SleepSession.
 *   - HR-zone display types ([HrZone]/[HrZoneSet]/[TimeInZone]) live in HrZones.kt.
 *   - HRV result type ([HrvAnalyzer.HrvResult]) lives in HrvAnalyzer.kt.
 *
 * All `ts` / `start` / `end` are wall-clock unix SECONDS (Long) to match the
 * com.noop.data layer; the Swift source uses Int seconds.
 *
 * All derived intensity / energy / sleep-stage outputs are APPROXIMATE and not
 * medical advice (see the per-analyzer Swift headers).
 */

/** On-device analytics namespace marker. Mirrors Swift `StrandAnalytics`. */
object StrandAnalytics {
    const val VERSION: String = "0.1.0"
}

// ─────────────────────────────────────────────────────────────────────────────
// UserProfile (WorkoutDetector.swift)
// ─────────────────────────────────────────────────────────────────────────────

/** User profile for HRmax + calorie estimation. Mirrors Swift `UserProfile`. */
data class UserProfile(
    val weightKg: Double = 70.0,
    val heightCm: Double = 170.0,
    val age: Double = 30.0,
    /** "male" | "female" | "nonbinary". */
    val sex: String = "nonbinary",
    /**
     * Counter ticks per real step for the @57 motion counter (#139). The WHOOP 5/MG
     * counter overcounts and its true tick rate is unknown, so the daily-steps total
     * divides by this. 1.0 = raw pass-through (default); the engine clamps ≥ 0.5.
     */
    val stepTicksPerStep: Double = 1.0,
    /**
     * Waist circumference (cm) for the Fitness Age VO₂max estimate (Phase 2). 0 = not set.
     * Optional — it UNLOCKS the VO₂max readout but does NOT sharpen the headline Fitness Age
     * (the body term cancels out of the age formula). Default param so existing call-sites compile.
     */
    val waistCm: Double = 0.0,
)

// ─────────────────────────────────────────────────────────────────────────────
// Sleep staging output shapes (SleepStager.swift)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * A contiguous sleep-stage segment. Times are wall-clock unix seconds.
 * Mirrors Swift `StageSegment` (Codable → encoded verbatim into stagesJSON).
 * `start`/`end` are `var` so the stager can extend the trailing segment in place.
 */
data class StageSegment(
    var start: Long,
    var end: Long,
    /** "wake" | "light" | "deep" | "rem". */
    var stage: String,
    var state: String? = null,
    var sleepProbability: Double? = null,
    var pWake: Double? = null,
    var pLight: Double? = null,
    var pDeep: Double? = null,
    var pRem: Double? = null,
    var evidenceCoverage: Double? = null,
    var abstentionReason: String? = null,
    var computationMode: String? = null,
    var algorithmVersion: String? = null,
    var probabilitiesCalibrated: Boolean? = null,
)

object SleepStageSemantics {
    fun normalized(segments: List<StageSegment>, start: Long, end: Long): List<StageSegment> {
        if (end <= start) return emptyList()
        val out = ArrayList<StageSegment>()
        var cursor = start
        for (original in segments.sortedBy { it.start }) {
            val lo = maxOf(cursor, original.start); val hi = minOf(end, original.end)
            if (hi <= lo) continue
            if (lo > cursor) out.add(unknown(cursor, lo))
            out.add(original.copy(start = lo, end = hi)); cursor = hi
        }
        if (cursor < end) out.add(unknown(cursor, end))
        return out
    }
    fun isSleep(segment: StageSegment): Boolean {
        if (segment.state in listOf("state_unknown", "off_body", "awake")) return false
        return segment.stage in listOf("light", "deep", "rem", "sleep_unstaged") ||
            (segment.stage == "unknown" && segment.state == "sleep_unstaged")
    }
    fun isKnownState(segment: StageSegment): Boolean = isSleep(segment) ||
        ((segment.state == null || segment.state == "awake") && SleepStageVocabulary.isWake(segment.stage))
    fun coalesced(segments: List<StageSegment>): List<StageSegment> {
        val out = ArrayList<StageSegment>()
        for (s in segments) {
            val last = out.lastOrNull()
            if (last != null && last.end == s.start && s.copy(start = last.start, end = last.end) == last)
                out[out.lastIndex] = last.copy(end = s.end)
            else out.add(s)
        }
        return out
    }
    /** Causal mode never calls the retrospective model; only independently available context qualifies. */
    fun applyingContext(segments: List<StageSegment>, start: Long, end: Long,
                        context: List<SleepContextSpan> = emptyList(), mode: String = "retrospective",
                        observedThrough: Long? = null): List<StageSegment> {
        if (end <= start) return emptyList()
        val cutoff = minOf(end, observedThrough ?: end)
        val base = normalized(segments, start, end)
        val cuts = sortedSetOf(start, end, maxOf(start, cutoff))
        base.forEach { cuts.add(it.start); cuts.add(it.end) }
        context.filter { it.end > start && it.start < end }.forEach {
            cuts.add(maxOf(start, it.start)); cuts.add(minOf(end, it.end))
        }
        if (mode == "causal") {
            var t = Math.floorDiv(start, 30L) * 30
            while (t < end) { if (t > start) cuts.add(t); t += 30 }
        }
        fun priority(c: SleepContextSpan): Int = when {
            c.kind == "off_body" -> 3
            c.kind in listOf("awake", "reading", "phone_use") -> 2
            c.qualifiedBinarySleep -> 1
            else -> 0
        }
        return coalesced(cuts.toList().zipWithNext().map { (lo, hi) ->
            var s = (base.firstOrNull { it.start <= lo && it.end >= hi } ?: unknown(lo, hi)).copy(start = lo, end = hi)
            if (lo >= cutoff) unknown(lo, hi, "not_observed_yet", mode = mode)
            else {
                if (mode == "causal") s = unknown(lo, hi, "causal_stage_model_unavailable", mode = mode)
                val c = context.filter { it.start <= lo && it.end >= hi &&
                    (mode != "causal" || (it.availableAt ?: it.end) <= hi) }.maxByOrNull(::priority)
                if (c != null && priority(c) > 0) {
                    val off = c.kind == "off_body"; val awake = priority(c) == 2
                    if (off || awake || !isKnownState(s)) s = StageSegment(lo, hi,
                        if (awake) "wake" else "unknown", state = if (off) "off_body" else if (awake) "awake" else "sleep_unstaged",
                        evidenceCoverage = s.evidenceCoverage, abstentionReason = "context:${c.kind}:${c.provenance}",
                        computationMode = mode, algorithmVersion = "sleep-context-v1", probabilitiesCalibrated = false)
                }
                s
            }
        })
    }
    fun unknown(start: Long, end: Long, reason: String = "no_epoch_observations", coverage: Double = 0.0,
                mode: String = "retrospective") = StageSegment(start, end, "unknown", state = "state_unknown",
        evidenceCoverage = coverage, abstentionReason = reason, computationMode = mode,
        algorithmVersion = "sleep-evidence-v2", probabilitiesCalibrated = false)
}

data class SleepContextSpan(val start: Long, val end: Long, val kind: String, val provenance: String,
                            val qualifiedBinarySleep: Boolean = false, val availableAt: Long? = null)

/**
 * A detected sleep session (in-bed span) with APPROXIMATE staging.
 *
 * Named [DetectedSleep] (NOT SleepSession) to avoid clashing with the Room
 * entity com.noop.data.SleepSession. Mirrors Swift `SleepSession` (the analytics
 * shape in SleepStager.swift), one-to-one.
 */
data class DetectedSleep(
    val start: Long,
    val end: Long,
    /** asleep / in-bed in [0, 1] (AASM TST/TIB; asleep = in-bed − wake). */
    val efficiency: Double,
    val stages: List<StageSegment>,
    /** Lowest 5-min rolling-mean HR during the session (bpm), or null. */
    val restingHR: Int?,
    /** Mean RMSSD over 5-min windows across the session (ms), or null. */
    val avgHRV: Double?,
    /**
     * Staged WITHOUT a motion spine, from heart rate alone (#1801).
     *
     * True only for a strap that streams HR but banks no motion, where Stage 0's gravity-stillness spine
     * has nothing to work with. Such a night is weaker by construction, not by tuning: with motion gone a
     * quiet evening at rest can sit in the sleep band. It is allowed to describe itself — duration,
     * stages, Rest — and must NOT reach anything it cannot be unwound from, which is why
     * [restingHR] and [avgHRV] are left null on one rather than filtered out downstream.
     */
    val hrOnly: Boolean = false,
    val episodeType: String? = null,
    val groupedNightId: String? = null,
    val boundaryProvenance: String? = null,
    val denominatorKind: String? = null,
) {
    val hasKnownState: Boolean get() = stages.any(SleepStageSemantics::isKnownState)
}

/**
 * AASM-style metrics from a session's stage segments.
 * Mirrors Swift `SleepStager.HypnogramMetrics`.
 */
data class HypnogramMetrics(
    val tibS: Double,
    val tstS: Double,
    val sptS: Double,
    val solS: Double,
    /** NaN if no REM. */
    val remLatencyS: Double,
    val wasoS: Double,
    val efficiency: Double,
    val disturbances: Int,
    val deepMin: Double,
    val remMin: Double,
    val lightMin: Double,
    val deepPct: Double,
    val remPct: Double,
    val lightPct: Double,
)

// ─────────────────────────────────────────────────────────────────────────────
// Workout detection output shapes (WorkoutDetector.swift)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Per-record motion-intensity sample. Mirrors Swift `WorkoutDetector.ActivityPoint`.
 */
data class ActivityPoint(
    val ts: Long,
    val intensity: Double,
)

/**
 * A detected workout window. All intensity fields are APPROXIMATE.
 * Mirrors Swift `ExerciseSession`.
 */
data class ExerciseSession(
    val start: Long,
    val end: Long,
    val avgHR: Double,
    val peakHR: Int,
    val strain: Double?,
    val durationS: Double,
    /** Edwards zone (0–5) time breakdown as % of HR samples; sums to 100. */
    val zoneTimePct: Map<Int, Double>,
    /** Mean Karvonen %HRR over the bout, clamped [0, 100], or null. */
    val avgHRRPct: Double?,
    /** Effective HRmax used for zone math (bpm), or null. */
    val hrmax: Double?,
    /** "caller" | "observed" | "tanaka" | "unknown". */
    val hrmaxSource: String,
    val caloriesKcal: Double?,
    val caloriesKJ: Double?,
    /** #1545: how much of the bout the HR sensor actually saw, as a percentage of 60-second buckets that
     *  contain at least one reading. null when not measured. A WHOOP 4.0's optical sensor is weak under
     *  gripping — exactly what lifting is — so a low Effort has two very different causes: the metric not
     *  rating the work, or the strap not having seen it. Those deserve opposite advice. */
    val hrCoveragePct: Double? = null,
)

// ─────────────────────────────────────────────────────────────────────────────
// Personal baselines (Baselines.swift)
// ─────────────────────────────────────────────────────────────────────────────

/** Per-metric configuration for the baseline model. Mirrors Swift `MetricCfg`. */
data class MetricCfg(
    /** Physiological lower bound (hard reject below). */
    val minVal: Double,
    /** Physiological upper bound (hard reject above). */
    val maxVal: Double,
    /** σ_floor: minimum dispersion. */
    val floorSpread: Double,
    /** Baseline-center half-life (nights). */
    val halfLifeB: Double,
    /** Spread half-life (nights, slower than center). */
    val halfLifeS: Double,
)

/**
 * Baseline status flags (cold-start → trusted → stale).
 * Mirrors Swift `BaselineStatus` (String-raw-valued enum); [raw] preserves the
 * exact lowercase wire string the Swift `rawValue` used.
 */
enum class BaselineStatus(val raw: String) {
    /** Fewer than MIN_NIGHTS_SEED valid nights; no score yet. */
    CALIBRATING("calibrating"),
    /** Between seed and trust thresholds; usable, higher uncertainty. */
    PROVISIONAL("provisional"),
    /** At least MIN_NIGHTS_TRUST valid nights. */
    TRUSTED("trusted"),
    /** Usable but no update for > STALE_DAYS nights. */
    STALE("stale"),
}

/**
 * Immutable snapshot of a personal baseline for one metric after N nights.
 * Mirrors Swift `BaselineState`.
 */
data class BaselineState(
    /** Robust EWMA center (the personal "mean"). */
    val baseline: Double,
    /**
     * EWMA of absolute deviations, floored at cfg.floorSpread. Multiply by 1.253
     * to approximate Gaussian σ.
     */
    val spread: Double,
    /** Count of valid nights contributing to the state. */
    val nValid: Int,
    /** Consecutive nights with no valid value (staleness tracking). */
    val nightsSinceUpdate: Int,
    /** Cold-start / staleness status. */
    val status: BaselineStatus,
) {
    /** True iff fully trusted (not calibrating or stale). */
    val trusted: Boolean get() = status == BaselineStatus.TRUSTED

    /** True iff at least provisionally usable (nValid ≥ MIN_NIGHTS_SEED). */
    val usable: Boolean
        get() = status == BaselineStatus.PROVISIONAL || status == BaselineStatus.TRUSTED
}

/** Three forms of deviation from a personal baseline. Mirrors Swift `Deviation`. */
data class Deviation(
    /** Robust z-score: (value − baseline) / (1.253 × spread). */
    val z: Double,
    /** Signed physical-units delta: value − baseline. */
    val delta: Double,
    /** Fractional deviation: value / baseline − 1. */
    val ratio: Double,
    /** True iff |z| ≤ 1.0. */
    val inNormalRange: Boolean,
)

// ─────────────────────────────────────────────────────────────────────────────
// Engine orchestration shapes (AnalyticsEngine.swift)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Baselines passed in by the caller (built from prior nights via Baselines).
 * Mirrors Swift `AnalyticsEngine.ProfileBaselines`.
 */
data class ProfileBaselines(
    val hrv: BaselineState? = null,
    val restingHR: BaselineState? = null,
    val resp: BaselineState? = null,
    val skinTemp: BaselineState? = null,
)

/**
 * The full analysis result for one day. Mirrors Swift `AnalyticsEngine.DayResult`.
 *
 * NOTE: [daily] is the Room entity com.noop.data.DailyMetric (cache shape, with
 * recovery/strain/sleep rolled up). The detected sleep sessions are the analytics
 * [DetectedSleep] shape; persistence to com.noop.data.SleepSession rows is wired
 * by the caller (the engine port maps DetectedSleep → SleepSession when upserting).
 */
data class DayResult(
    /** DailyMetric in the Room cache shape (recovery/strain/sleep rolled up). */
    val daily: com.noop.data.DailyMetric,
    /** Detected sleep sessions (rich, with stage segments). */
    val sleepSessions: List<DetectedSleep>,
    /** Detected workout/exercise sessions. */
    val workouts: List<ExerciseSession>,
    /** Charge (recovery) score [0,100] or null (cold-start / no HRV baseline). */
    val recovery: Double?,
    /** Effort (strain) score [0,100] or null (insufficient HR samples / invalid HRR). */
    val strain: Double?,
    /**
     * Rest (sleep_performance) composite [0,100] or null (no asleep time). The persistence /
     * series layer stores this under the `sleep_performance` key. Replaces the bare efficiency
     * proxy (duration-vs-need 0.50 + efficiency 0.20 + restorative 0.20 + consistency 0.10).
     */
    val rest: Double? = null,
    /**
     * Wear-gated mean in-bed skin temperature (°C) for this night, or null when no worn in-bed
     * samples were available. Baseline-INDEPENDENT (like avgHrv): the caller seeds a personal
     * skin-temp baseline from these nightly means and re-derives [com.noop.data.DailyMetric.skinTempDevC]
     * in a second pass. APPROXIMATE. (PR #85)
     */
    val nightlySkinTempC: Double? = null,
    /** Per-score certainty tier for Charge (recovery). Mirrors Swift. */
    val chargeConfidence: ScoreConfidence = ScoreConfidence.CALIBRATING,
    /** Per-score certainty tier for Effort (strain). Mirrors Swift. */
    val effortConfidence: ScoreConfidence = ScoreConfidence.CALIBRATING,
    /** Per-score certainty tier for Rest (sleep_performance composite). Mirrors Swift. */
    val restConfidence: ScoreConfidence = ScoreConfidence.CALIBRATING,
    /**
     * Per-session per-epoch MOTION magnitudes (H8), keyed by each matched session's detected start
     * ([DetectedSleep.start]), on the same 30 s epoch grid as that session's `stagesJSON`. The caller
     * persists these via `WhoopRepository.persistSessionMotion` after upserting the sleep-session rows. A
     * session with too little gravity to grid is OMITTED (no key), so the caller never persists a fabricated
     * zero series. Mirrors Swift `DayResult.sessionMotionByStart`. (H8)
     */
    val sessionMotionByStart: Map<Long, List<Double>> = emptyMap(),
    /**
     * Per-session per-epoch BAND sleep_state (#175), keyed by each matched session's detected start, on the
     * same 30 s grid as `stagesJSON` / [sessionMotionByStart]. The strap's OWN @81 code (0 wake/1 still/2
     * asleep/3 up) gridded per session, for the caller to persist via `WhoopRepository.persistSessionSleepState`.
     * A session with no band-state samples is OMITTED (no key), so the caller persists NULL there rather than a
     * fabricated array. Feeds the H7 re-onset CONFIRM guard on the NEXT pass; never overrides the derived
     * hypnogram. Empty on a WHOOP 4.0. Mirrors Swift `DayResult.sessionSleepStateByStart`. (#175)
     */
    val sessionSleepStateByStart: Map<Long, List<Int>> = emptyMap(),
    /**
     * Whether this day's on-device sleep staging ran on SPARSE motion coverage
     * ([SleepStager.isGravitySparse], #345) — the same signal that downgrades Rest confidence. The caller
     * stamps it onto each persisted `SleepSession.stagingSparse` so the Sleep tab can caption a possibly
     * under-detected night ("slept 8h, shows 1h"). Transient (not persisted on DayResult itself). Mirrors
     * the value Swift's `analyzeDay` writes directly onto its `CachedSleepSession.stagingSparse`.
     */
    val gravitySparse: Boolean = false,
    /**
     * #1545: where the detector lost every candidate workout on this day. null only when detection did not
     * run. Always populated otherwise — including (especially) when [workouts] is empty, which is the case
     * the counts exist to explain. Trailing + defaulted so every existing construction site is unchanged.
     */
    val detectionFunnel: WorkoutDetector.DetectionFunnel? = null,
    val hrvMeasurements: List<HrvWindowResult> = emptyList(),
    val hrvBaselines: List<HrvSeries.Baseline> = emptyList(),
    val hrvNightSummary: HrvSeries.Summary? = null,
)
