package com.noop.analytics

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.sqrt

typealias HrvWindowResult = HrvWindow.Result

/** Five-minute event-time measurements; engineering thresholds are not clinical cutoffs. */
object HrvWindow {
    const val SECONDS = 300
    const val ALGORITHM_VERSION = "observed-pair-rmssd-v2"
    data class Policy(
        val minimumObservedFraction: Double = 0.90,
        val minimumValidIntervalFraction: Double = 0.90,
        val minimumAcceptedDurationFraction: Double = 0.80,
        val maximumCorrectionFraction: Double = 0.10,
        val maximumGapSeconds: Double = 30.0,
        val minimumPairs: Int = 20,
        val version: String = "engineering-shadow-90-v2",
    )
    data class Result(
        val start: Int, val end: Int, val userId: String?, val deviceId: String?,
        val deviceFirmware: String?, val source: String?, val modality: String?, val inputRevision: String, val computationMode: String,
        val algorithmVersion: String, val qualityVersion: String, val metric: String, val unit: String,
        val observedRMSSD: Double?, val correctedRMSSD: Double?, val sdnn: Double?, val researchObservedRMSSD: Double?,
        val originalIds: List<String>, val pairMask: List<Boolean>, val correctedPairMask: List<Boolean>, val pairReasons: List<String?>,
        val observedTimeFraction: Double, val observedSpans: List<PhysiologyQuality.Span>, val acceptedDurationSeconds: Double,
        val validIntervalFraction: Double, val validPairCount: Int, val correctedPairCount: Int,
        val correctedMethodVersion: String?, val correctionPasses: List<String>, val maximumGapSeconds: Double,
        val correctionFraction: Double, val correctionEventCount: Int,
        val insertedEventCount: Int, val deletedEventCount: Int,
        val measurementValid: Boolean, val reason: String?, val context: String,
        val baselineEligible: Boolean, val baselineReason: String?, val timingPrecisionSeconds: Double?,
        val decoderVersions: List<String>, val clockVersions: List<String>,
    ) {
        /** Publication revisions do not change an otherwise identical physiological measurement. */
        fun sameMeasurement(other: Result): Boolean = this == other.copy(inputRevision = inputRevision)
    }
    fun alignedStart(epoch: Int): Int = floor(epoch.toDouble() / 300).toInt() * 300

    fun measure(start: Int, observations: List<PhysiologyQuality.IntervalObservation>,
                context: List<PhysiologyQuality.ContextEpoch> = emptyList(), policy: Policy = Policy(),
                inputRevision: String = "unversioned", computationMode: String = "retrospective"): Result {
        val lo = start.toDouble()
        val hi = lo + 300
        val inWindow = observations.filter { row -> row.eventTime >= lo && row.eventTime < hi ||
            row.verifiedSpan?.let { it.start < hi && it.end > lo } == true }
        val unique = mutableMapOf<List<String>, PhysiologyQuality.IntervalObservation>()
        val conflictingKeys = mutableSetOf<List<String>>()
        var conflict = false
        for (row in inWindow) {
            val key = listOf(row.userId, row.deviceId, row.source, row.originalId)
            if (key in conflictingKeys) continue
            val old = unique[key]
            if (old != null && old != row) { conflict = true; conflictingKeys.add(key); unique.remove(key) }
            else unique[key] = row
        }
        val rows = unique.values.sortedWith(compareBy<PhysiologyQuality.IntervalObservation> { (it.verifiedSpan?.end ?: it.eventTime).takeIf { v -> v.isFinite() } ?: Double.POSITIVE_INFINITY }
            .thenBy { it.continuityGroup ?: "" }.thenBy { it.ordinal ?: -1 }.thenBy { it.originalId })
        fun proof(row: PhysiologyQuality.IntervalObservation): Boolean = !row.startBeatId.isNullOrEmpty() &&
            !row.endBeatId.isNullOrEmpty() && row.startBeatId != row.endBeatId &&
            !row.continuityGroup.isNullOrEmpty() && row.originalId.isNotEmpty()
        fun validTiming(row: PhysiologyQuality.IntervalObservation): Boolean {
            if (!row.timestampPrecisionSeconds.isFinite() || row.timestampPrecisionSeconds <= 0 || !row.eventTime.isFinite()) return false
            val span = row.verifiedSpan ?: return true
            // Clock uncertainty never expands the fixed RR quantization tolerance.
            return row.clockVersion.isNotEmpty() && row.clockVersion != "unknown" && row.timestampPrecisionSeconds <= 0.020 &&
                span.start.isFinite() && span.end.isFinite() && span.end > span.start && row.originalRRMs.isFinite() &&
                abs((span.end - span.start) - row.originalRRMs / 1000) <= 0.002001
        }
        val rejectedBeats = mutableSetOf<List<String>>()
        for (row in rows) {
            if (row.startBeatId != null && !row.startBeatAccepted) rejectedBeats.add(listOf(row.userId, row.deviceId, row.source, row.startBeatId))
            if (row.endBeatId != null && !row.endBeatAccepted) rejectedBeats.add(listOf(row.userId, row.deviceId, row.source, row.endBeatId))
        }
        fun originalAccepted(row: PhysiologyQuality.IntervalObservation): Boolean = row.originalAccepted &&
            row.startBeatAccepted && row.endBeatAccepted && !row.rhythmAmbiguous && row.originalRRMs.isFinite() &&
            row.originalRRMs in 250.0..2500.0 && proof(row) &&
            listOf(row.userId, row.deviceId, row.source, row.startBeatId ?: "") !in rejectedBeats &&
            listOf(row.userId, row.deviceId, row.source, row.endBeatId ?: "") !in rejectedBeats
        fun successive(a: PhysiologyQuality.IntervalObservation, b: PhysiologyQuality.IntervalObservation): Boolean {
            if (!proof(a) || !proof(b) || a.continuityGroup != b.continuityGroup || a.source != b.source ||
                a.deviceId != b.deviceId || a.userId != b.userId || a.endBeatId != b.startBeatId || a.startBeatId == b.endBeatId) return false
            if (a.verifiedSpan != null && b.verifiedSpan != null && abs(a.verifiedSpan.end - b.verifiedSpan.start) > 0.000001) return false
            return true
        }
        fun inside(row: PhysiologyQuality.IntervalObservation): Boolean = row.verifiedSpan?.let { it.start >= lo && it.end <= hi }
            ?: (row.eventTime >= lo && row.eventTime < hi)
        val accepted = rows.map(::originalAccepted)
        val pairMask = MutableList(rows.size) { false }
        val correctedPairMask = MutableList(rows.size) { false }
        val pairReasons = MutableList<String?>(rows.size) { "continuity_break" }
        if (rows.isNotEmpty()) pairReasons[0] = "window_boundary"
        val observedDifferences = mutableListOf<Double>()
        val correctedDifferences = mutableListOf<Double>()
        for (index in 1 until rows.size) {
            val a = rows[index - 1]; val b = rows[index]
            if (!successive(a, b)) continue
            if (!inside(a) || !inside(b)) { pairReasons[index] = "window_boundary"; continue }
            pairMask[index] = accepted[index - 1] && accepted[index]
            pairReasons[index] = if (pairMask[index]) null else "rejected_original_beat"
            if (pairMask[index]) observedDifferences.add(b.originalRRMs - a.originalRRMs)
            val ca = a.correctedRRMs ?: if (accepted[index - 1]) a.originalRRMs else Double.NaN
            val cb = b.correctedRRMs ?: if (accepted[index]) b.originalRRMs else Double.NaN
            if (ca.isFinite() && cb.isFinite() && ca in 250.0..2500.0 && cb in 250.0..2500.0 &&
                !a.rhythmAmbiguous && !b.rhythmAmbiguous) { correctedPairMask[index] = true; correctedDifferences.add(cb - ca) }
        }
        fun rms(values: List<Double>): Double? = if (values.isEmpty()) null else sqrt(values.sumOf { it * it } / values.size)
        val spans = PhysiologyQuality.union(rows.filter { proof(it) && validTiming(it) }.mapNotNull { it.verifiedSpan }, lo, hi)
        val duration = spans.sumOf { it.end - it.start }
        val acceptedSpans = PhysiologyQuality.union(rows.filter { originalAccepted(it) && validTiming(it) }.mapNotNull { it.verifiedSpan }, lo, hi)
        val acceptedDuration = acceptedSpans.sumOf { it.end - it.start }
        var gap = 0.0; var through = lo
        for (span in spans) { gap = maxOf(gap, span.start - through); through = span.end }
        gap = maxOf(gap, hi - through)
        val validFraction = if (rows.isEmpty()) 0.0 else accepted.count { it }.toDouble() / rows.size
        val events = mutableMapOf<List<String>, PhysiologyQuality.Correction>()
        for (row in rows) for (event in row.corrections) events[listOf(row.userId, row.deviceId, row.source, row.originalId, event.pass, event.id)] = event
        val affected = rows.count { it.corrections.isNotEmpty() || it.correctedRRMs != null }
        val correctionFraction = if (rows.isEmpty()) 0.0 else affected.toDouble() / rows.size
        val users = rows.map { it.userId }.toSet(); val devices = rows.map { it.deviceId }.toSet()
        val sources = rows.map { it.source }.toSet(); val modalities = rows.map { it.modality }.toSet()
        val firmware = rows.map { it.deviceFirmware }.toSet()
        val endpointKeys = rows.filter(::proof).map { listOf(it.userId, it.deviceId, it.source, it.startBeatId, it.endBeatId) }
        val reason: String? = when {
            alignedStart(start) != start -> "unaligned_window"
            computationMode !in listOf("retrospective", "causal") -> "invalid_computation_mode"
            conflict -> "original_identity_conflict"
            !policy.minimumObservedFraction.isFinite() || policy.minimumObservedFraction !in 0.0..1.0 ||
                !policy.minimumValidIntervalFraction.isFinite() || policy.minimumValidIntervalFraction !in 0.0..1.0 ||
                !policy.minimumAcceptedDurationFraction.isFinite() || policy.minimumAcceptedDurationFraction !in 0.0..1.0 ||
                !policy.maximumCorrectionFraction.isFinite() || policy.maximumCorrectionFraction !in 0.0..1.0 ||
                !policy.maximumGapSeconds.isFinite() || policy.maximumGapSeconds < 0 || policy.minimumPairs < 1 -> "invalid_quality_policy"
            rows.isEmpty() -> "no_observations"
            rows.any { it.userId.isEmpty() || it.deviceId.isEmpty() || it.source.isEmpty() || it.originalId.isEmpty() } -> "missing_identity"
            users.size != 1 || devices.size != 1 -> "owner_mismatch"
            sources.size != 1 -> "source_switch"
            firmware.size != 1 || rows.map { it.decoderVersion }.toSet().size != 1 || rows.map { it.clockVersion }.toSet().size != 1 -> "acquisition_version_switch"
            modalities.size != 1 || rows.first().modality !in listOf("ppg_ibi", "ecg_nn") -> "unsupported_modality"
            rows.none(::proof) -> "continuity_unverified"
            endpointKeys.toSet().size != endpointKeys.size -> "duplicate_interval_identity"
            rows.any { !validTiming(it) } -> "invalid_timing_metadata"
            rows.any { it.correctedRRMs != null && it.corrections.isEmpty() } -> "missing_correction_provenance"
            spans.isEmpty() -> "timing_coverage_unverified"
            rows.any { it.rhythmAmbiguous } -> "rhythm_ambiguity"
            duration / 300 < policy.minimumObservedFraction -> "insufficient_observed_time"
            gap > policy.maximumGapSeconds -> "acquisition_gap"
            validFraction < policy.minimumValidIntervalFraction -> "insufficient_original_intervals"
            acceptedDuration / 300 < policy.minimumAcceptedDurationFraction -> "insufficient_accepted_duration"
            correctionFraction > policy.maximumCorrectionFraction -> "correction_burden"
            observedDifferences.size < policy.minimumPairs -> "insufficient_original_pairs"
            else -> null
        }
        val epochs = context.filter { it.start < hi && it.end > lo }
        fun available(epoch: PhysiologyQuality.ContextEpoch): Boolean = epoch.qualified &&
            (computationMode != "causal" || epoch.availableAt?.let { it.isFinite() && it <= hi } == true)
        val states = epochs.map { if (available(it)) it.state else "unknown" }.toSet()
        val contextSpans = PhysiologyQuality.union(epochs.filter(::available).map { PhysiologyQuality.Span(it.start, it.end) }, lo, hi)
        val contextDuration = contextSpans.sumOf { it.end - it.start }
        val state = states.singleOrNull() ?: if (states.isEmpty()) "unknown" else "mixed"
        val eligibleContext = state in listOf("sleep", "nap", "quiet_rest") && contextDuration >= 300 - 0.000001
        val baselineReason = reason ?: if (eligibleContext) null else
            if (state in listOf("sleep", "nap", "quiet_rest")) "context_coverage_insufficient" else "context_$state"
        return Result(start, start + SECONDS, users.singleOrNull(), devices.singleOrNull(), firmware.singleOrNull(), sources.singleOrNull(), modalities.singleOrNull(),
            inputRevision, computationMode, ALGORITHM_VERSION, policy.version, "rmssd", "ms", if (reason == null) rms(observedDifferences) else null,
            if (reason == null && affected > 0 && correctedDifferences.size >= policy.minimumPairs) rms(correctedDifferences) else null,
            if (reason == null) HrvAnalyzer.sdnnRaw(rows.filter { originalAccepted(it) && inside(it) }.map { it.originalRRMs }) else null,
            if (users.size == 1 && devices.size == 1 && sources.size == 1 && modalities.size == 1 &&
                rows.firstOrNull()?.modality in listOf("ppg_ibi", "ecg_nn") && !conflict) rms(observedDifferences) else null,
            rows.map { it.originalId }, pairMask, correctedPairMask, pairReasons, duration / 300, spans, acceptedDuration, validFraction,
            observedDifferences.size, correctedDifferences.size, if (affected > 0) "corrected-original-timeline-rmssd-v1" else null,
            events.values.map { it.pass }.toSet().sorted(), gap, correctionFraction, events.size, events.values.count { it.kind == "inserted" },
            events.values.count { it.kind == "deleted" }, reason == null, reason, state, reason == null && eligibleContext, baselineReason,
            rows.map { it.timestampPrecisionSeconds }.filter { it.isFinite() && it > 0 }.maxOrNull(), rows.map { it.decoderVersion }.toSet().sorted(), rows.map { it.clockVersion }.toSet().sorted())
    }
}
