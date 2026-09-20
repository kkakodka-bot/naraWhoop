package com.noop.analytics

import kotlin.math.*

/** Transparent shadow spectral/autocorrelation estimator. Engineering gates are not clinical cutoffs. */
object RespirationEstimator {
    const val VERSION = "resp-spectrum-acf-1"
    const val PREPROCESS_VERSION = "masked-linear-detrend-hann-1"
    data class Input(
        val start: Double, val sampleRateHz: Double, val values: List<Double>,
        val observed: List<Boolean>, val source: String, val modality: String,
        val timingVerified: Boolean, val channelVerified: Boolean,
        val motionContaminated: Boolean = false, val inputRevision: String = "local",
        val maximumSupportedRate: Double? = null,
    )
    data class Policy(
        val minimumRate: Double = 4.0, val maximumRate: Double = 40.0,
        val minimumObservedFraction: Double = 0.9, val maximumGapSeconds: Double = 2.0,
        val minimumCycles: Double = 5.0, val minimumStandardDeviation: Double = 0.01,
        val minimumSpectralFraction: Double = 0.45, val minimumAutocorrelation: Double = 0.5,
        val maximumDisagreement: Double = 1.5, val harmonicPowerRatio: Double = 0.2,
    )
    data class Result(
        val start: Double, val end: Double, val breathsPerMinute: Double?, val reason: String?,
        val observedTimeFraction: Double, val maximumGapSeconds: Double,
        val spectralRate: Double?, val autocorrelationRate: Double?,
        val spectralFraction: Double?, val autocorrelation: Double?, val effectiveCycles: Double?,
        val source: String, val modality: String, val inputRevision: String,
        val minimumRate: Double, val maximumRate: Double,
        val acceptedSpans: List<PhysiologyQuality.Span> = emptyList(),
        val methodVersion: String = VERSION, val preprocessVersion: String = PREPROCESS_VERSION,
        val publicationMode: String = "shadow", val computationMode: String = "windowed_retrospective",
    )

    fun estimate(input: Input, policy: Policy = Policy()): Result {
        val n = input.values.size
        val rate = input.sampleRateHz
        val duration = if (rate.isFinite() && rate > 0) n / rate else 0.0
        val maximumRate = min(policy.maximumRate, input.maximumSupportedRate ?: policy.maximumRate)
        var coverage = 0.0; var maxGap = duration
        var spectralRate: Double? = null; var acfRate: Double? = null
        var spectralFraction: Double? = null; var acfStrength: Double? = null; var cycles: Double? = null
        var acceptedSpans = emptyList<PhysiologyQuality.Span>()
        fun result(reason: String?, estimate: Double? = null) = Result(input.start, input.start + duration,
            estimate, reason, coverage, maxGap, spectralRate, acfRate, spectralFraction, acfStrength,
            cycles, input.source, input.modality, input.inputRevision, policy.minimumRate, maximumRate, acceptedSpans)
        if (!input.start.isFinite() || !rate.isFinite() || rate < 1 || rate > 128 || n !in 32..16384 ||
            input.observed.size != n || duration < 32 || duration > 300 ||
            !(policy.minimumRate > 0 && maximumRate.isFinite() && maximumRate > policy.minimumRate) ||
            policy.maximumRate >= 0.8 * rate * 30) return result("unsupported_shape_or_rate")
        if (!input.timingVerified) return result("timing_unverified")
        if (!input.channelVerified) return result("channel_semantics_unverified")
        if (input.motionContaminated) return result("motion_contamination")
        val mask = input.values.indices.map { input.observed[it] && input.values[it].isFinite() }
        coverage = mask.count { it }.toDouble() / n
        acceptedSpans = PhysiologyQuality.union(mask.indices.filter { mask[it] }.map {
            PhysiologyQuality.Span(input.start + it / rate, input.start + (it + 1) / rate)
        }, input.start, input.start + duration)
        var run = 0; var longest = 0
        for (observed in mask) { run = if (observed) 0 else run + 1; longest = max(longest, run) }
        maxGap = longest / rate
        if (coverage < policy.minimumObservedFraction) return result("insufficient_observed_time")
        if (maxGap > policy.maximumGapSeconds) return result("acquisition_gap")
        val count = mask.count { it }.toDouble()
        val meanT = mask.indices.filter { mask[it] }.sumOf { it.toDouble() } / count
        val meanY = mask.indices.filter { mask[it] }.sumOf { input.values[it] } / count
        val denominator = mask.indices.filter { mask[it] }.sumOf { (it - meanT).pow(2) }
        val slope = mask.indices.filter { mask[it] }.sumOf { (it - meanT) * (input.values[it] - meanY) } / denominator
        val x = input.values.indices.map { if (mask[it]) input.values[it] - meanY - slope * (it - meanT) else 0.0 }
        val variance = x.sumOf { it * it } / count
        if (sqrt(variance) < policy.minimumStandardDeviation) return result("weak_modulation")
        val highestBin = min(n / 2 - 1, floor(min(90.0, rate * 24) * duration / 60).toInt())
        val firstBin = max(1, ceil(2 * duration / 60).toInt())
        val power = DoubleArray(highestBin + 1)
        for (k in firstBin..highestBin) {
            var real = 0.0; var imaginary = 0.0
            for (i in x.indices) {
                val windowed = x[i] * (0.5 - 0.5 * cos(2 * PI * i / (n - 1)))
                val angle = 2 * PI * k * i / n
                real += windowed * cos(angle); imaginary -= windowed * sin(angle)
            }
            power[k] = real * real + imaginary * imaginary
        }
        val peak = (firstBin..highestBin).maxByOrNull { power[it] } ?: return result("weak_modulation")
        spectralRate = peak * 60.0 / duration
        val totalPower = power.sum()
        spectralFraction = ((peak - 1)..(peak + 1)).filter { it in power.indices }.sumOf { power[it] } / totalPower
        if (spectralRate < policy.minimumRate || spectralRate > maximumRate) return result("out_of_supported_range")
        if (!spectralFraction.isFinite() || spectralFraction < policy.minimumSpectralFraction) return result("weak_periodicity")
        val lagLo = max(1, floor(60 * rate / maximumRate).toInt())
        val lagHi = min(n / 2, ceil(60 * rate / policy.minimumRate).toInt())
        val acf = DoubleArray(lagHi + 2) { -1.0 }
        for (lag in 1..(lagHi + 1)) {
            var cross = 0.0; var left = 0.0; var right = 0.0; var pairs = 0
            for (i in lag until n) if (mask[i] && mask[i - lag]) {
                cross += x[i] * x[i - lag]; left += x[i] * x[i]; right += x[i - lag] * x[i - lag]; pairs++
            }
            if (pairs >= (n - lag) * policy.minimumObservedFraction && left > 0 && right > 0) acf[lag] = cross / sqrt(left * right)
        }
        val peaks = (max(2, lagLo)..min(lagHi, n - 2)).filter {
            acf[it] >= acf[it - 1] && acf[it] > acf[it + 1] && acf[it] >= policy.minimumAutocorrelation
        }
        val lag = peaks.firstOrNull() ?: return result("weak_autocorrelation")
        val denom = acf[lag - 1] - 2 * acf[lag] + acf[lag + 1]
        val shift = if (abs(denom) > 1e-12) (0.5 * (acf[lag - 1] - acf[lag + 1]) / denom).coerceIn(-0.5, 0.5) else 0.0
        acfRate = 60 * rate / (lag + shift); acfStrength = acf[lag]
        if (!acfRate.isFinite() || acfRate < policy.minimumRate || acfRate > maximumRate)
            return result("out_of_supported_range")
        val harmonic = listOf(peak / 2.0, peak * 2.0).any { bin ->
            val k = bin.roundToInt()
            k in firstBin..highestBin && abs(k - peak) > 2 && power[k] >= power[peak] * policy.harmonicPowerRatio
        }
        if (harmonic) return result("harmonic_ambiguity")
        if (abs(acfRate - spectralRate) > policy.maximumDisagreement) return result("spectral_autocorrelation_disagreement")
        cycles = duration * coverage * acfRate / 60
        if (cycles < policy.minimumCycles) return result("insufficient_cycles")
        val estimate = (spectralRate + acfRate) / 2
        if (!estimate.isFinite() || estimate < policy.minimumRate || estimate > maximumRate)
            return result("out_of_supported_range")
        return result(null, estimate)
    }

    /** A sampled tachogram is eligible only inside verified original spans; gaps are never filled. */
    fun fromIntervals(start: Double, duration: Int, observations: List<PhysiologyQuality.IntervalObservation>,
                      inputRevision: String = "local"): Input {
        require(duration in 32..300 && start.isFinite())
        val rows = observations.distinct().sortedBy { it.verifiedSpan?.start ?: it.eventTime }
        val ownership = rows.map { listOf(it.userId, it.deviceId, it.source, it.modality, it.clockVersion) }.distinct()
        val identities = rows.groupBy { it.originalId }
        val verified = rows.isNotEmpty() && ownership.size == 1 && identities.values.all { it.size == 1 } && rows.all {
            val span = it.verifiedSpan
            span != null && span.start.isFinite() && span.end.isFinite() && span.end > span.start &&
                it.eventTime.isFinite() && it.originalRRMs.isFinite() &&
                abs((span.end - span.start) - it.originalRRMs / 1000) <= 0.002001 &&
                it.timestampPrecisionSeconds.isFinite() && it.timestampPrecisionSeconds > 0 && it.timestampPrecisionSeconds <= .020 &&
                !it.startBeatId.isNullOrEmpty() && !it.endBeatId.isNullOrEmpty() &&
                !it.continuityGroup.isNullOrEmpty() && it.clockVersion.isNotEmpty() && it.clockVersion != "unknown" && it.decoderVersion != "unknown" &&
                it.modality in listOf("ecg_nn", "ppg_ibi")
        }
        // Clock uncertainty cannot widen RR quantization, and a shared rejected beat stays rejected.
        val rejectedBeats = rows.flatMap { row -> listOfNotNull(
            row.startBeatId.takeIf { !row.startBeatAccepted }, row.endBeatId.takeIf { !row.endBeatAccepted }) }.toSet()
        fun endpointsAccepted(row: PhysiologyQuality.IntervalObservation) = row.startBeatAccepted && row.endBeatAccepted &&
            row.startBeatId !in rejectedBeats && row.endBeatId !in rejectedBeats
        val values = MutableList(duration * 4) { Double.NaN }; val mask = MutableList(duration * 4) { false }
        if (verified) for (i in 1 until rows.size) {
            val a = rows[i - 1]; val b = rows[i]; val sa = a.verifiedSpan!!; val sb = b.verifiedSpan!!
            if (a.endBeatId != b.startBeatId || a.continuityGroup != b.continuityGroup ||
                abs(sa.end - sb.start) > 0.002 || !a.originalAccepted || !b.originalAccepted ||
                !endpointsAccepted(a) || !endpointsAccepted(b) || a.rhythmAmbiguous || b.rhythmAmbiguous ||
                a.corrections.isNotEmpty() || b.corrections.isNotEmpty()) continue
            val left = (sa.start + sa.end) / 2; val right = (sb.start + sb.end) / 2
            if (right <= left || right - left > 2) continue
            for (j in values.indices) {
                val t = start + j / 4.0
                if (t >= left && t < right) {
                    values[j] = a.originalRRMs + (b.originalRRMs - a.originalRRMs) * (t - left) / (right - left)
                    mask[j] = true
                }
            }
        }
        val maximumRate = if (verified) 24.0 / rows.maxOf { it.verifiedSpan!!.end - it.verifiedSpan.start } else null
        return Input(start, 4.0, values, mask, rows.firstOrNull()?.source ?: "unavailable", "rsa_ibi_ms",
            verified, verified, inputRevision = inputRevision, maximumSupportedRate = maximumRate)
    }

    data class Fusion(val breathsPerMinute: Double?, val reason: String?, val methods: List<String>, val evidenceStrength: Double?)

    /** Correlated channels never multiply confidence; disagreement is retained as abstention. */
    fun fuse(results: List<Result>, maximumDisagreement: Double = 1.5): Fusion {
        val accepted = results.filter { it.reason == null && it.breathsPerMinute != null }
        if (accepted.isEmpty()) return Fusion(null, "no_eligible_channels", emptyList(), null)
        if (accepted.map { Triple(it.start, it.end, it.inputRevision) }.distinct().size != 1)
            return Fusion(null, "channel_windows_not_aligned", accepted.map { it.modality }, null)
        val rates = accepted.map { it.breathsPerMinute!! }.sorted()
        if (rates.last() - rates.first() > maximumDisagreement) return Fusion(null, "cross_channel_disagreement", accepted.map { it.modality }, null)
        return Fusion((rates[(rates.size - 1) / 2] + rates[rates.size / 2]) / 2, null,
            accepted.map { it.modality }, accepted.mapNotNull { it.autocorrelation }.minOrNull())
    }

    data class Summary(val median: Double?, val mean: Double?, val acceptedSeconds: Double, val coverage: Double,
                       val acceptedWindows: Int, val totalWindows: Int, val context: String,
                       val distributionBpm: List<Double> = emptyList())

    /** Overlapping strides contribute to duration once. Sleep and awake-rest summaries stay separate. */
    fun summarize(results: List<Result>, start: Double, end: Double, context: String): Summary {
        require(end > start && context in listOf("qualified_sleep", "qualified_awake_rest"))
        val inPeriod = results.filter { it.start >= start && it.end <= end }
        val accepted = inPeriod.filter { it.reason == null && it.breathsPerMinute != null }
        val values = accepted.map { it.breathsPerMinute!! }.sorted()
        val seconds = PhysiologyQuality.union(accepted.flatMap { it.acceptedSpans }, start, end)
            .sumOf { it.end - it.start }
        val median = if (values.isEmpty()) null else (values[(values.size - 1) / 2] + values[values.size / 2]) / 2
        return Summary(median, if (values.isEmpty()) null else values.average(), seconds, seconds / (end - start),
            accepted.size, inPeriod.size, context, values)
    }
}
