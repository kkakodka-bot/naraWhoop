package com.noop.analytics

import kotlin.math.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class RespirationEstimatorTest {
    private fun wave(start: Double = 0.0, bpm: Double = 12.0) = RespirationEstimator.Input(start, 4.0,
        (0 until 480).map { sin(2 * PI * bpm * it / 240) }, List(480) { true }, "fixture", "respiratory_modulation", true, true)

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
        val dropped = RespirationEstimator.fromIntervals(0.0, 120, rows.filter { it.eventTime < 40 || it.eventTime >= 50 })
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
        val valid = RespirationEstimator.fromIntervals(0.0, 120, rsaRows())
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
        assertEquals(12.0, summary.median!!, 0.1)
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
}
