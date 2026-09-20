package com.noop.analytics

import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.floor

/** Context-specific summaries and past-only comparison; measurements are never baseline-clipped. */
object HrvSeries {
    /** Retrospective stage feature gates signal validity, never baseline/sleep eligibility. */
    fun feature(time: Int, measurements: List<HrvWindow.Result>): HrvWindow.Result? {
        val rows = measurements.filter { it.start <= time && time < it.end }
        val first = rows.firstOrNull() ?: return null
        return first.takeIf { it.measurementValid && rows.all { row -> row.sameMeasurement(first) } }
    }
    data class Baseline(val version: String, val windowDays: Int, val effectiveSampleCount: Int,
        val excludedZeroCount: Int, val logMedian: Double?, val logMAD: Double?, val logDeviation: Double?,
        val robustZ: Double?, val reason: String?)
    data class Summary(val context: String, val meanRMSSD: Double?, val medianRMSSD: Double?,
        val durationWeightedMeanRMSSD: Double?, val distribution: List<Double>, val eligibleWindowCount: Int,
        val excludedWindowCount: Int, val acceptedDurationSeconds: Double, val opportunitySeconds: Double,
        val samplingCoverage: Double, val segmentCoverage: List<Double>, val representative: Boolean,
        val reason: String?, val version: String)
    data class SummaryPolicy(val minimumSamplingCoverage: Double = 0.50,
        val minimumSegmentCoverage: Double = 0.10, val minimumWindows: Int = 3,
        val version: String = "engineering-night-thirds-v1")

    fun windows(start: Int, end: Int, observations: List<PhysiologyQuality.IntervalObservation>,
                context: List<PhysiologyQuality.ContextEpoch> = emptyList(), policy: HrvWindow.Policy = HrvWindow.Policy(),
                inputRevision: String = "unversioned", computationMode: String = "retrospective"): List<HrvWindow.Result> {
        if (end <= start) return emptyList()
        val starts = (HrvWindow.alignedStart(start) until end step HrvWindow.SECONDS).toList()
        val lo = starts.first().toDouble(); val hi = starts.last() + 300.0
        val buckets = mutableMapOf<Int, MutableList<PhysiologyQuality.IntervalObservation>>()
        for (row in observations) {
            val owners = mutableSetOf<Int>()
            if (row.eventTime.isFinite() && row.eventTime >= lo && row.eventTime < hi) owners.add(HrvWindow.alignedStart(floor(row.eventTime).toInt()))
            row.verifiedSpan?.let { span ->
                if (span.start.isFinite() && span.end.isFinite()) {
                    val a = maxOf(lo, span.start); val b = minOf(hi, span.end)
                    if (b > a) {
                        var cursor = HrvWindow.alignedStart(floor(a).toInt())
                        while (cursor < b) { owners.add(cursor); cursor += 300 }
                    }
                }
            }
            for (owner in owners) buckets.getOrPut(owner) { mutableListOf() }.add(row)
        }
        return starts.map {
            HrvWindow.measure(it, buckets[it] ?: emptyList(), context, policy, inputRevision, computationMode)
        }
    }
    private fun median(values: List<Double>): Double? {
        if (values.isEmpty()) return null
        val sorted = values.sorted(); val n = sorted.size
        return if (n % 2 == 0) (sorted[n / 2 - 1] + sorted[n / 2]) / 2 else sorted[n / 2]
    }
    private fun sameSeries(a: HrvWindow.Result, b: HrvWindow.Result): Boolean =
        a.userId == b.userId && a.deviceId == b.deviceId && a.deviceFirmware == b.deviceFirmware && a.source == b.source && a.modality == b.modality &&
            a.metric == b.metric && a.unit == b.unit && a.algorithmVersion == b.algorithmVersion &&
            a.qualityVersion == b.qualityVersion && a.computationMode == b.computationMode &&
            a.decoderVersions == b.decoderVersions && a.clockVersions == b.clockVersions && a.end - a.start == b.end - b.start
    private fun comparable(a: HrvWindow.Result, b: HrvWindow.Result): Boolean = sameSeries(a, b) && a.context == b.context
    private fun unambiguous(windows: List<HrvWindow.Result>): List<HrvWindow.Result> = windows.groupBy { it.start }.values
        .mapNotNull { rows -> rows.first().takeIf { first -> rows.all { it.sameMeasurement(first) } } }.sortedBy { it.start }

    fun baseline(current: HrvWindow.Result, history: List<HrvWindow.Result>, windowDays: Int = 28,
                 minimumSamples: Int = 20): Baseline {
        // A changed validity/context result must invalidate its older eligible counterpart first.
        val candidates = unambiguous(history.filter { it.end <= current.start &&
            it.start >= current.start.toLong() - maxOf(0, windowDays).toLong() * 86400 &&
            sameSeries(current, it) }).filter { it.baselineEligible && it.measurementValid && it.context == current.context }
        val values = candidates.mapNotNull { it.observedRMSSD }.filter { it.isFinite() && it >= 0 }
        val positives = values.filter { it > 0 }.map(::ln)
        val center = median(positives)
        val mad = center?.let { m -> median(positives.map { abs(it - m) }) }
        val reason = when {
            windowDays <= 0 || minimumSamples < 1 -> "invalid_baseline_policy"
            !current.measurementValid || !current.baselineEligible -> current.baselineReason ?: "ineligible_measurement"
            positives.size < minimumSamples -> "insufficient_baseline"
            current.observedRMSSD == 0.0 -> "zero_not_log_transformable"
            current.observedRMSSD == null || current.observedRMSSD < 0 || !current.observedRMSSD.isFinite() -> "unusable_measurement"
            else -> null
        }
        val deviation = if (reason == null) ln(current.observedRMSSD!!) - center!! else null
        val z = deviation?.let { d -> mad?.takeIf { it > 0 }?.let { d / (1.4826 * it) } }
        return Baseline("past-log-median-mad-v1", windowDays, positives.size, values.size - positives.size,
            center, mad, deviation, z, reason ?: if (mad == 0.0) "zero_baseline_dispersion" else null)
    }

    fun summarize(windows: List<HrvWindow.Result>, start: Int, end: Int, context: String = "sleep",
                  policy: SummaryPolicy = SummaryPolicy()): Summary {
        val overlapping = windows.filter { it.start < end && it.end > start }
        val overlappingCount = overlapping.map { it.start }.toSet().size
        val inEpisode = unambiguous(overlapping.filter { it.start >= start && it.end <= end })
        val eligible = inEpisode.filter { it.measurementValid && it.baselineEligible && it.context == context &&
            it.observedRMSSD?.isFinite() == true && it.observedRMSSD >= 0 }
        val homogeneous = eligible.firstOrNull()?.let { first -> eligible.all { comparable(first, it) } } ?: true
        val values = eligible.mapNotNull { it.observedRMSSD }
        val opportunity = maxOf(0, end - start).toDouble()
        val accepted = eligible.sumOf { it.acceptedDurationSeconds }
        val observed = eligible.sumOf { it.observedTimeFraction * 300 }
        val observedSpans = eligible.flatMap { it.observedSpans }
        val thirds = (0 until 3).map { part ->
            val a = start + opportunity * part / 3; val b = a + opportunity / 3
            if (b <= a) 0.0 else PhysiologyQuality.union(observedSpans, a, b).sumOf { it.end - it.start } / (b - a)
        }
        val coverage = if (opportunity > 0) observed / opportunity else 0.0
        val reason = when {
            opportunity <= 0 || !policy.minimumSamplingCoverage.isFinite() || policy.minimumSamplingCoverage !in 0.0..1.0 ||
                !policy.minimumSegmentCoverage.isFinite() || policy.minimumSegmentCoverage !in 0.0..1.0 || policy.minimumWindows < 1 -> "invalid_summary_policy"
            !homogeneous -> "incompatible_measurements"
            values.size < policy.minimumWindows -> "insufficient_windows"
            coverage < policy.minimumSamplingCoverage || thirds.any { it < policy.minimumSegmentCoverage } -> "unrepresentative_sampling"
            else -> null
        }
        val weighted = if (accepted > 0) eligible.sumOf { it.observedRMSSD!! * it.acceptedDurationSeconds } / accepted else null
        return Summary(context, if (reason == null) values.average() else null,
            if (homogeneous) median(values) else null, if (homogeneous) weighted else null,
            if (homogeneous) values.sorted() else emptyList(), eligible.size, overlappingCount - eligible.size,
            accepted, opportunity, coverage, thirds, reason == null, reason, policy.version)
    }
}
