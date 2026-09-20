package com.noop.analytics

import com.noop.data.RrInterval
import org.junit.Assert.*
import org.junit.Test

class HrvIntegrationTest {
    private val profile = UserProfile(weightKg = 75.0, heightCm = 178.0, age = 30.0, sex = "male")
    private fun observations() = hrvEvidence() + hrvEvidence(start = 300, pattern = listOf(950.0, 1050.0)) +
        hrvEvidence(start = 600, pattern = listOf(600.0, 1400.0))
    @Test fun enginePublishesWindowArithmeticNotCachedVendorValueOrDeepOnlyPreference() {
        val provided = DetectedSleep(0, 900, 1.0, listOf(StageSegment(0, 900, "light")), null, 999.0)
        val result = AnalyticsEngine.analyzeDay("1970-01-01", hrvObservations = observations(),
            hrvContext = listOf(PhysiologyQuality.ContextEpoch(0.0, 900.0, "sleep", true)), inputRevision = "revision-7",
            profile = profile, providedSleep = listOf(provided), deepHrvWindow = true, localDayStart = 0, localDayEndExclusive = 1800)
        assertEquals(300.0, result.daily.avgHrv!!, 1e-9); assertEquals(300.0, result.hrvNightSummary!!.meanRMSSD!!, 1e-9)
        assertEquals(300.0, result.sleepSessions.first().avgHRV!!, 1e-9); assertEquals(6, result.hrvMeasurements.size)
        assertTrue(result.hrvMeasurements.all { it.inputRevision == "revision-7" })
    }
    @Test fun sessionLegacyRowsStayUnavailableWithReason() {
        val rows = (0 until 900).map { RrInterval("d", it.toLong(), 1000) }
        val windows = SleepStager.sessionHrvWindows(0, 900, rows, emptyList())
        assertEquals(3, windows.size); assertTrue(windows.all { it.rmssd == null && it.unavailableReason == "continuity_unverified" })
        assertNull(SleepStager.sessionAvgHRV(0, 900, rows))
    }
    @Test fun finalBinarySleepContextIsUsedWithoutUserAnnotation() {
        val provided = DetectedSleep(0, 900, 1.0, listOf(StageSegment(0, 900, "sleep_unstaged", state = "sleep_unstaged")), null, null)
        val result = AnalyticsEngine.analyzeDay("1970-01-01", hrvObservations = observations(), profile = profile,
            providedSleep = listOf(provided), localDayStart = 0, localDayEndExclusive = 1800)
        assertEquals(300.0, result.daily.avgHrv!!, 1e-9); assertEquals("sleep", result.hrvMeasurements.first().context)
    }
    @Test fun stageFeaturesUseValidityWithoutSleepLabelAndCannotBypassQuality() {
        val rows = (0 until 300).map { RrInterval("d", it.toLong(), 1000) }
        val grid = SleepStager.buildEpochGrid(0.0, 300.0, emptyList(), emptyList(), emptyList(), rows, emptyList())
        val legacy = SleepStager.extractFeatures(grid, emptyList(), emptyList(), 0, 9)
        assertTrue(legacy.all { it.rmssd.isNaN() && it.sdnn.isNaN() })
        val measurement = HrvWindow.measure(0, hrvEvidence(pattern = listOf(600.0, 1400.0)))
        assertFalse(measurement.baselineEligible); assertTrue(measurement.measurementValid)
        val proven = SleepStager.extractFeatures(grid, emptyList(), emptyList(), 0, 9, listOf(measurement))
        assertTrue(proven.all { it.rmssd == 800.0 && it.sdnn.isFinite() })
    }
    @Test fun causalEngineExcludesIncompleteWindowsAndFutureContext() {
        val result = AnalyticsEngine.analyzeDay("1970-01-01", hrvObservations = observations(),
            hrvContext = listOf(PhysiologyQuality.ContextEpoch(0.0, 900.0, "sleep", true, 900.0)),
            profile = profile, localDayStart = 0, localDayEndExclusive = 1800, sleepComputationMode = "causal", sleepObservedThrough = 450)
        assertEquals(1, result.hrvMeasurements.size); assertEquals("causal", result.hrvMeasurements.first().computationMode)
        assertEquals("unknown", result.hrvMeasurements.first().context)
        assertTrue(result.hrvMeasurements.first().measurementValid); assertFalse(result.hrvMeasurements.first().baselineEligible)
    }

    @Test fun retrospectiveMeasurementCutoffPublishesOnlyClosedWindows() {
        for (cutoff in listOf(0L, 299L, 300L, 450L, 600L, 900L)) {
            val result = AnalyticsEngine.analyzeDay("1970-01-01", hrvObservations = observations(),
                hrvContext = listOf(PhysiologyQuality.ContextEpoch(0.0, 900.0, "sleep", true)),
                profile = profile, localDayStart = 0, localDayEndExclusive = 1800,
                measurementObservedThrough = cutoff)
            assertEquals((cutoff / 300).toInt(), result.hrvMeasurements.size)
            assertTrue(result.hrvMeasurements.all { it.end <= cutoff && it.computationMode == "retrospective" })
        }
    }
}
