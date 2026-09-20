package com.noop.analytics

import kotlin.math.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class RespirationEstimatorTest {
    private val clean = RespirationEstimator.Contamination(1.0, evidenceVersion = "synthetic-motion-v1")
    private fun wave(start: Double = 0.0, bpm: Double = 12.0) = RespirationEstimator.Input(start, 4.0,
        (0 until 480).map { sin(2 * PI * bpm * it / 240) }, List(480) { true }, "fixture", "respiratory_modulation", true, true, contamination = clean)

    @Test fun sharedSyntheticOracle() {
        val json = javaClass.classLoader!!.getResourceAsStream("respiration_oracle.json")!!.bufferedReader().use { it.readText() }
        val cases = JSONObject(json).getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i); val n = c.getInt("duration") * 4
            val values = (0 until n).map { j ->
                val angle = 2 * PI * c.getDouble("rate") * j / 240
                c.getDouble("amplitude") * sin(angle) + c.optDouble("harmonic", 0.0) * sin(2 * angle)
            }
            val mask = (0 until n).map { j -> j / 4.0 < c.optDouble("gap_start", 1e9) || j / 4.0 >= c.optDouble("gap_end", 1e9) }
            val r = RespirationEstimator.estimate(wave().copy(values = values, observed = mask,
                maximumSupportedRate = if (c.has("maximum_supported_rate")) c.getDouble("maximum_supported_rate") else null))
            assertEquals(c.getString("id"), if (c.has("reason")) c.getString("reason") else null, r.reason)
            if (c.has("expected_rate")) assertEquals(c.getString("id"), c.getDouble("expected_rate"), r.breathsPerMinute!!, 0.1)
            else assertNull(r.breathsPerMinute)
            assertEquals("shadow", r.publicationMode)
        }
    }
    @Test fun rejectsUnknownSemanticsAndMotion() {
        assertEquals("channel_semantics_unverified", RespirationEstimator.estimate(wave().copy(channelVerified = false)).reason)
        assertEquals("timing_unverified", RespirationEstimator.estimate(wave().copy(timingVerified = false)).reason)
        assertEquals("motion_contamination", RespirationEstimator.estimate(wave().copy(motionContaminated = true)).reason)
        assertEquals("unsupported_shape_or_rate", RespirationEstimator.estimate(wave().copy(observed = emptyList())).reason)
    }
    @Test fun intervalAdapterRequiresOriginalChainAndDoesNotFillGaps() {
        val rows = hrvEvidence(count = 150)
        val complete = RespirationEstimator.fromIntervals(0.0, 120, rows)
        assertTrue(complete.timingVerified); assertFalse(complete.observed.first()); assertTrue(complete.observed[4])
        val coarse = RespirationEstimator.fromIntervals(0.0, 120, rows.map { it.copy(verifiedSpan = null) })
        assertEquals("timing_unverified", RespirationEstimator.estimate(coarse).reason)
        val dropped = RespirationEstimator.fromIntervals(0.0, 120, rows.filter { it.eventTime < 40 || it.eventTime >= 50 }, contamination = clean)
        assertFalse(dropped.observed[45 * 4]); assertEquals("acquisition_gap", RespirationEstimator.estimate(dropped).reason)
        val conflict = RespirationEstimator.fromIntervals(0.0, 120, rows + rows[0].copy(originalRRMs = 1100.0))
        assertFalse(conflict.timingVerified)
    }
    private fun rsaRows(spanError: Double = 0.0, precision: Double = .020): List<PhysiologyQuality.IntervalObservation> {
        var cursor = 0.0
        return (0 until 360).map { index ->
            val rr = 1000 + 100 * sin(2 * PI * cursor / 5)
            val end = cursor + rr / 1000 + spanError
            val row = PhysiologyQuality.IntervalObservation(originalId = "i$index", deviceId = "device", source = "fixture",
                eventTime = cursor, originalRRMs = rr, startBeatId = "b$index", endBeatId = "b${index + 1}",
                continuityGroup = "verified", verifiedSpan = PhysiologyQuality.Span(cursor, end), timestampPrecisionSeconds = precision,
                decoderVersion = "fixture-v1", clockVersion = "verified-v1")
            cursor = end
            row
        }
    }
    @Test fun rsaClockUncertaintyCannotExpandOriginalRRDurationTolerance() {
        val valid = RespirationEstimator.fromIntervals(0.0, 120, rsaRows(), contamination = clean)
        assertTrue(valid.timingVerified)
        assertNotNull(RespirationEstimator.estimate(valid).breathsPerMinute)
        assertTrue(RespirationEstimator.fromIntervals(0.0, 120, rsaRows(spanError = .002)).timingVerified)
        for (rows in listOf(rsaRows(spanError = .030), rsaRows(spanError = .00201), rsaRows(precision = 0.0), rsaRows(precision = .021))) {
            assertFalse(HrvWindow.measure(0, rows).measurementValid)
            val input = RespirationEstimator.fromIntervals(0.0, 120, rows)
            assertFalse(input.timingVerified)
            assertTrue(input.observed.none { it })
            assertEquals("timing_unverified", RespirationEstimator.estimate(input).reason)
        }
    }
    @Test fun rsaRejectedSharedEndpointCannotContributeObservedSamples() {
        val rows = rsaRows().toMutableList()
        rows[50] = rows[50].copy(startBeatAccepted = false)
        val input = RespirationEstimator.fromIntervals(0.0, 120, rows)
        val affected = input.observed.indices.filter {
            it / 4.0 >= rows[49].verifiedSpan!!.start && it / 4.0 < rows[50].verifiedSpan!!.end
        }
        assertTrue(input.timingVerified)
        assertTrue(input.observed[40])
        assertTrue(affected.isNotEmpty())
        assertTrue(affected.none { input.observed[it] })
    }
    @Test fun overlappingWindowsNeverDoubleCountDuration() {
        val results = listOf(RespirationEstimator.estimate(wave()), RespirationEstimator.estimate(wave(60.0)))
        val summary = RespirationEstimator.summarize(results, 0.0, 300.0, "qualified_sleep")
        assertEquals(180.0, summary.acceptedSeconds, 1e-9); assertEquals(0.6, summary.coverage, 1e-9)
        assertNull(summary.median); assertNull(summary.mean)
        assertEquals("insufficient_accepted_duration", summary.reason)
    }
    @Test fun upsamplingDoesNotInventBandwidthAndFusionDoesNotMultiplyConfidence() {
        assertEquals("out_of_supported_range", RespirationEstimator.estimate(wave(bpm = 30.0).copy(maximumSupportedRate = 24.0)).reason)
        val first = RespirationEstimator.estimate(wave())
        val fused = RespirationEstimator.fuse(listOf(first, first.copy(modality = "ppg_amplitude")))
        assertEquals(first.autocorrelation, fused.evidenceStrength)
        assertEquals("cross_channel_disagreement", RespirationEstimator.fuse(listOf(first, RespirationEstimator.estimate(wave(bpm = 18.0)))).reason)
        assertEquals("channel_windows_not_aligned", RespirationEstimator.fuse(listOf(first, RespirationEstimator.estimate(wave(60.0)))).reason)
    }
    @Test fun summaryDistributionRetainsOnlyAcceptedInContextValuesInStableOrder() {
        val results=listOf(RespirationEstimator.estimate(wave(60.0,18.0)),
            RespirationEstimator.estimate(wave(bpm=24.0).copy(motionContaminated=true)),
            RespirationEstimator.estimate(wave()),RespirationEstimator.estimate(wave(240.0,30.0)))
        val summary=RespirationEstimator.summarize(results,0.0,300.0,"qualified_sleep")
        assertEquals(2,summary.distributionBpm.size)
        assertEquals(2,summary.acceptedWindows)
        assertEquals(3,summary.totalWindows)
        assertEquals(12.0,summary.distributionBpm[0],0.1); assertEquals(18.0,summary.distributionBpm[1],0.1)
        assertEquals(summary,RespirationEstimator.summarize(results.reversed(),0.0,300.0,"qualified_sleep"))
        val empty=RespirationEstimator.summarize(listOf(results[1]),0.0,300.0,"qualified_awake_rest")
        assertTrue(empty.distributionBpm.isEmpty());assertNull(empty.mean);assertNull(empty.median)
    }
    @Test fun motionEvidenceIsRequiredAndKnownContaminationRemainsAttributed() {
        for (evidence in listOf(RespirationEstimator.Contamination(),
            RespirationEstimator.Contamination(.89, evidenceVersion = "verified"),
            RespirationEstimator.Contamination(1.01, evidenceVersion = "verified"), RespirationEstimator.Contamination(1.0))) {
            assertEquals("motion_evidence_unavailable", RespirationEstimator.estimate(wave().copy(contamination = evidence)).reason)
        }
        assertEquals("motion_contamination", RespirationEstimator.estimate(wave().copy(contamination = clean.copy(motionContaminated = true))).reason)
        val result = RespirationEstimator.estimate(wave().copy(contamination = clean.copy(signalQualityReasons = listOf("low_perfusion"))))
        assertEquals("signal_quality_contamination", result.reason)
        assertTrue("low_perfusion" in result.rejectionReasons)
        assertEquals("resp-quality-2", result.qualityPolicyVersion)
    }
    private fun train(count: Int = 300, modality: String = "ppg_ibi", baseMs: Double = 1000.0,
                      source: (Int) -> String = { "source" }): List<PhysiologyQuality.IntervalObservation> {
        var time = 0.0
        return (0 until count).map { index ->
            val rr = baseMs + if (baseMs == 1000.0) 0.0 else 5 * sin(2 * PI * time / 5)
            val row = PhysiologyQuality.IntervalObservation("i$index", deviceId = "d", source = source(index),
                modality = modality, eventTime = time, originalRRMs = rr, startBeatId = "b$index", endBeatId = "b${index + 1}",
                continuityGroup = "original", verifiedSpan = PhysiologyQuality.Span(time, time + rr / 1000),
                timestampPrecisionSeconds = .001, decoderVersion = "fixture", clockVersion = "fixture")
            time += rr / 1000
            row
        }
    }
    @Test fun impossibleIbiNeverEntersInterpolationAndPlausibilityIsModalitySpecific() {
        val impossible = RespirationEstimator.fromIntervals(0.0, 120, train(count = 1500, baseMs = 100.0), contamination = clean)
        assertTrue(impossible.timingVerified); assertTrue(impossible.observed.none { it })
        assertEquals("interval_out_of_plausibility", RespirationEstimator.estimate(impossible).reason)
        val optical = RespirationEstimator.fromIntervals(0.0, 120, train(count = 60, baseMs = 2700.0), contamination = clean)
        val ecg = RespirationEstimator.fromIntervals(0.0, 120, train(count = 60, modality = "ecg_nn", baseMs = 2700.0), contamination = clean)
        assertTrue(optical.observed.none { it }); assertTrue(ecg.observed.count { it } > 450)
        assertTrue("interval_out_of_plausibility" in optical.inputRejectionReasons)
    }
    @Test fun sourceChangesAreScopedToEachWindowAndNeverInterpolatedAcross() {
        val across = train(source = { if (it < 120) "first" else "second" })
        assertTrue(RespirationEstimator.fromIntervals(0.0, 120, across).timingVerified)
        assertTrue(RespirationEstimator.fromIntervals(120.0, 120, across).timingVerified)
        val inside = RespirationEstimator.fromIntervals(60.0, 120, across)
        assertFalse(inside.timingVerified); assertTrue(inside.observed.none { it })
    }
    @Test fun mixedTimingAndKnownSignalRejectionsCannotBecomeCleanRespiration() {
        val rows = rsaRows() + PhysiologyQuality.IntervalObservation("unverified", deviceId = "device", source = "fixture", eventTime = 50.0, originalRRMs = 1000.0)
        assertEquals("timing_unverified", RespirationEstimator.estimate(RespirationEstimator.fromIntervals(0.0, 120, rows, contamination = clean)).reason)
        val rejected = rsaRows().map { it.copy(contactAccepted = false) }
        val input = RespirationEstimator.fromIntervals(0.0, 120, rejected, contamination = clean)
        assertTrue(input.observed.none { it }); assertTrue("contact_rejected" in input.inputRejectionReasons)
        assertNull(RespirationEstimator.estimate(input).breathsPerMinute)
    }
    @Test fun dominantSecondHarmonicWithWeakFundamentalCannotDoubleRate() {
        for (amplitude in listOf(.05, .1, .3)) {
            val values = (0 until 480).map { j -> val angle = 2 * PI * 12 * j / 240; amplitude * sin(angle) + sin(2 * angle) }
            val result = RespirationEstimator.estimate(wave().copy(values = values))
            assertNull(result.breathsPerMinute); assertEquals("harmonic_ambiguity", result.reason)
            assertEquals(24.0, result.spectralRate!!, .1)
        }
    }
    @Test fun malformedSpansAndCorrectionNeverAcquireTiming() {
        val malformed = train().toMutableList()
        malformed[50] = malformed[50].copy(verifiedSpan = PhysiologyQuality.Span(Double.NaN, Double.NaN))
        val unknown = RespirationEstimator.fromIntervals(0.0, 120, malformed, contamination = clean)
        assertFalse(unknown.timingVerified); assertEquals("timing_unverified", RespirationEstimator.estimate(unknown).reason)
        val corrected = train().toMutableList()
        corrected[50] = corrected[50].copy(corrections = listOf(PhysiologyQuality.Correction("correction", "fixture", "interpolation")), verifiedSpan = null)
        val missing = RespirationEstimator.fromIntervals(0.0, 120, corrected, contamination = clean)
        assertFalse(missing.timingVerified); assertTrue(missing.observed.none { it })
    }
    @Test fun tinyUnverifiedGapAndExtremeAlternationRemainMissing() {
        val gapped = train().toMutableList()
        gapped[50] = gapped[50].copy(verifiedSpan = PhysiologyQuality.Span(50.001, 51.001))
        val input = RespirationEstimator.fromIntervals(0.0, 120, gapped, contamination = clean)
        assertTrue(input.timingVerified); assertFalse(input.observed[200]); assertFalse(input.observed[203])
        var time = 0.0
        val alternating = (0 until 160).map { index ->
            val rr = if (index % 2 == 0) 300.0 else 1700.0
            val row = PhysiologyQuality.IntervalObservation("a$index", deviceId = "d", source = "s", eventTime = time,
                originalRRMs = rr, startBeatId = "b$index", endBeatId = "b${index + 1}", continuityGroup = "original",
                verifiedSpan = PhysiologyQuality.Span(time, time + rr / 1000), timestampPrecisionSeconds = .001,
                decoderVersion = "fixture", clockVersion = "fixture")
            time += rr / 1000; row
        }
        val ambiguous = RespirationEstimator.fromIntervals(0.0, 120, alternating, contamination = clean)
        assertTrue("rhythm_ambiguity" in ambiguous.inputRejectionReasons); assertTrue(ambiguous.observed.none { it })
        assertNull(RespirationEstimator.estimate(ambiguous).breathsPerMinute)
    }
    @Test fun nightRequiresDurationAndDistributedCoverageWhileRetainingDiagnostics() {
        val full = (0 until 3600 step 120).map { RespirationEstimator.estimate(wave(it.toDouble())) }
        val one = RespirationEstimator.summarize(listOf(full.first()), 0.0, 3600.0, "qualified_sleep")
        assertNull(one.median); assertNull(one.mean); assertEquals("insufficient_accepted_duration", one.reason)
        assertEquals(120.0, one.acceptedSeconds, 0.0); assertEquals(1, one.distributionBpm.size)
        val early = RespirationEstimator.summarize(full.take(16), 0.0, 3600.0, "qualified_sleep")
        assertNull(early.median); assertEquals("unrepresentative_temporal_coverage", early.reason)
        assertEquals(0.0, early.coverageByThird.last(), 0.0)
        val complete = RespirationEstimator.summarize(full, 0.0, 3600.0, "qualified_sleep")
        assertNull(complete.reason); assertEquals(12.0, complete.median!!, .1)
        assertEquals(listOf(1.0, 1.0, 1.0), complete.coverageByThird)
        assertEquals(complete, RespirationEstimator.summarize(full + full, 0.0, 3600.0, "qualified_sleep"))
        val mixedFirmware = full.toMutableList()
        mixedFirmware[15] = mixedFirmware[15].copy(acquisitionIdentity = listOf("changed-firmware"))
        assertEquals("incompatible_window_provenance", RespirationEstimator.summarize(mixedFirmware, 0.0, 3600.0, "qualified_sleep").reason)
    }
}
