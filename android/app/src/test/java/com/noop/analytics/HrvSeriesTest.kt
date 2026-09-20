package com.noop.analytics

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.ln

class HrvSeriesTest {
    @Test fun sourcesAreQualifiedSeparatelyInEachWindowAndNeverSpliced() {
        val rows = hrvEvidence(source = "whoop5_history") + hrvEvidence(start = 300, source = "channel:7") +
            hrvEvidence(start = 300, count = 1, source = "whoop5_history")
        val windows = HrvSeries.windows(0, 600, rows)
        assertEquals(listOf("whoop5_history", "channel:7"), windows.map { it.source }); assertTrue(windows.all { it.measurementValid })
        val partial = hrvEvidence(count = 150, source = "whoop5_history") + hrvEvidence(count = 150, offset = 150.0, source = "channel:7")
        assertFalse(HrvSeries.selectedWindow(0, partial).measurementValid)
        assertEquals("owner_mismatch", HrvSeries.selectedWindow(0, rows + hrvEvidence(deviceId = "other", source = "other")).reason)
    }
    @Test fun denseSingleNightAndSeriallyCorrelatedNightsCannotMatureBaseline() {
        val dense = (0 until 80).map { measured(it * 300, 100.0) }
        val single = HrvSeries.baseline(measured(86400, 100.0), dense, minimumSamples = 3)
        assertEquals(1, single.independentNightCount); assertEquals(1, single.effectiveSampleCount)
        assertEquals(80, single.observationCount); assertEquals("insufficient_baseline", single.reason)
        val trend = (0 until 12).map { measured(it * 86400, 50.0 + it * 10) }
        val serial = HrvSeries.baseline(measured(12 * 86400, 200.0), trend, minimumSamples = 3)
        assertEquals(12, serial.independentNightCount); assertTrue(serial.effectiveSampleCount < 3)
        assertEquals("serially_correlated_baseline", serial.reason); assertNull(serial.logDeviation)
        assertEquals(0, HrvSeries.baseline(measured(24000, 100.0), dense, minimumSamples = 3).effectiveSampleCount)
    }
    private fun measured(start: Int, value: Double, context: String = "sleep", firmware: String = "test-v1", revision: String = "unversioned"): HrvWindow.Result {
        val base = if (value > 750) 450.0 else 1000 - value
        return HrvWindow.measure(start, hrvEvidence(start = start, pattern = listOf(base, base + value, base + 2 * value, base + value), firmware = firmware),
            listOf(PhysiologyQuality.ContextEpoch(start.toDouble(), start + 300.0, context, true)), inputRevision = revision)
    }
    @Test fun nightlyArithmeticAndRestNapSeparation() {
        val r = HrvSeries.summarize(listOf(measured(0, 0.0), measured(300, 100.0), measured(600, 800.0)), 0, 900)
        assertEquals(300.0, r.meanRMSSD!!, 1e-9); assertEquals(100.0, r.medianRMSSD!!, 1e-9)
        assertEquals(1.0, r.samplingCoverage, 1e-9); assertEquals(listOf(1.0, 1.0, 1.0), r.segmentCoverage)
        assertEquals(900.0, r.acceptedDurationSeconds, 1e-9)
        val mixed = listOf(measured(0, 0.0, "nap"), measured(300, 100.0, "quiet_rest"), measured(600, 800.0))
        assertNull(HrvSeries.summarize(mixed, 0, 900).meanRMSSD); assertEquals(1, HrvSeries.summarize(mixed, 0, 900).eligibleWindowCount)
    }
    @Test fun denseEarlyIslandCannotRepresentNight() {
        val r = HrvSeries.summarize(listOf(measured(0, 100.0), measured(300, 100.0), measured(600, 100.0)), 0, 1800)
        assertEquals(0.5, r.samplingCoverage, 1e-9); assertEquals("unrepresentative_sampling", r.reason)
        assertEquals(listOf(1.0, 0.5, 0.0), r.segmentCoverage); assertNull(r.meanRMSSD)
    }
    @Test fun baselineUsesOnlyPastComparablePositiveMeasurements() {
        val history = listOf(measured(0, 100.0), measured(86400, 200.0), measured(172800, 400.0))
        val current = measured(259200, 800.0)
        val r = HrvSeries.baseline(current, history + history + listOf(current, measured(345600, 20.0)), minimumSamples = 3)
        assertNull(r.reason); assertEquals(3, r.effectiveSampleCount)
        assertEquals(ln(200.0), r.logMedian!!, 1e-9); assertEquals(ln(2.0), r.logMAD!!, 1e-9)
        assertEquals(ln(4.0), r.logDeviation!!, 1e-9)
        assertEquals("insufficient_baseline", HrvSeries.baseline(measured(1200, 800.0, firmware = "test-v2"), history, minimumSamples = 3).reason)
        assertEquals(0, HrvSeries.baseline(measured(1200, 800.0, "quiet_rest"), history, minimumSamples = 3).effectiveSampleCount)
    }
    @Test fun zerosAndColdStartAreExplicit() {
        val history = listOf(measured(0, 100.0), measured(86400, 100.0), measured(172800, 100.0))
        assertEquals("zero_not_log_transformable", HrvSeries.baseline(measured(259200, 0.0), history, minimumSamples = 3).reason)
        val flat = HrvSeries.baseline(measured(259200, 800.0), history, minimumSamples = 3)
        assertEquals("zero_baseline_dispersion", flat.reason); assertNull(flat.robustZ); assertNotNull(flat.logDeviation)
        val cold = HrvSeries.baseline(measured(86400, 100.0), listOf(measured(0, 0.0)))
        assertEquals("insufficient_baseline", cold.reason); assertEquals(1, cold.excludedZeroCount)
    }

    @Test fun recomputedOvernightOverlapIgnoresOnlyPublicationRevision() {
        val history = listOf(measured(0, 100.0, revision = "1"), measured(300, 200.0, revision = "1"), measured(600, 400.0, revision = "1"))
        val recomputed = listOf(measured(0, 100.0, revision = "2"), measured(300, 200.0, revision = "2"), measured(600, 400.0, revision = "2"))
        val current = measured(86400, 300.0, revision = "2")
        val expected = HrvSeries.baseline(current, history, minimumSamples = 3)
        assertEquals(expected, HrvSeries.baseline(current, history + recomputed, minimumSamples = 3))
        assertEquals(expected, HrvSeries.baseline(current, (history + recomputed).reversed(), minimumSamples = 3))
        assertEquals(3, HrvSeries.summarize(history + recomputed, 0, 900).eligibleWindowCount)
        assertNotNull(HrvSeries.feature(150, history + recomputed))
        val conflict = measured(0, 150.0, revision = "3")
        assertFalse(history[0].sameMeasurement(conflict))
        assertEquals(2, HrvSeries.baseline(current, history + conflict, minimumSamples = 3).observationCount)
        assertNull(HrvSeries.feature(150, history + conflict))
    }

    @Test fun summaryExclusionsCountOnlyUniqueOverlappingBuckets() {
        val windows = listOf(-300, 0, 300, 600, 900, 1200).map { measured(it, 100.0) }
        assertEquals(0, HrvSeries.summarize(windows, 0, 900).excludedWindowCount)
        val crossing = HrvSeries.summarize(windows, 150, 1050)
        assertEquals(2, crossing.eligibleWindowCount); assertEquals(2, crossing.excludedWindowCount)
        val duplicated = windows + measured(300, 100.0, revision = "new")
        assertEquals(0, HrvSeries.summarize(duplicated, 0, 900).excludedWindowCount)
        val conflicted = HrvSeries.summarize(duplicated + measured(300, 200.0), 0, 900)
        assertEquals(2, conflicted.eligibleWindowCount); assertEquals(1, conflicted.excludedWindowCount)
    }

    @Test fun invalidatedOrReclassifiedHistoryCannotRetainItsOldBaselineValue() {
        val history = listOf(measured(0, 100.0), measured(300, 200.0), measured(600, 400.0))
        val current = measured(86400, 300.0)
        val invalid = HrvWindow.measure(0, hrvEvidence(pattern = listOf(950.0, 1050.0)).map {
            it.copy(rhythmAmbiguous = true)
        }, listOf(PhysiologyQuality.ContextEpoch(0.0, 300.0, "sleep", true)), inputRevision = "new")
        assertFalse(invalid.measurementValid)
        for (revision in listOf(invalid, measured(0, 100.0, "awake", revision = "new"),
            measured(0, 100.0, "quiet_rest", revision = "new"))) {
            for (rows in listOf(history + revision, (history + revision).reversed())) {
                val result = HrvSeries.baseline(current, rows, minimumSamples = 3)
                assertEquals(2, result.observationCount)
                assertEquals("insufficient_baseline", result.reason)
            }
        }
        val expected = HrvSeries.baseline(current, history, minimumSamples = 3)
        val unrelated = listOf(history[0].copy(userId = "other"), history[0].copy(deviceId = "other"),
            history[0].copy(source = "other"), measured(0, 150.0, firmware = "test-v2"),
            history[0].copy(qualityVersion = "other"))
        assertEquals(expected, HrvSeries.baseline(current, history + unrelated, minimumSamples = 3))
    }
}
