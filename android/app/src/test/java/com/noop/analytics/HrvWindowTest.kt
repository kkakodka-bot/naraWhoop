package com.noop.analytics

import com.noop.protocol.ParsedFrame
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

internal fun hrvEvidence(start: Int = 0, count: Int = 300, pattern: List<Double> = listOf(1000.0),
                        offset: Double = 0.0, mode: String = "", deviceId: String = "d", firmware: String? = "test-v1"):
    List<PhysiologyQuality.IntervalObservation> {
    var time = start + offset
    val rows = mutableListOf<PhysiologyQuality.IntervalObservation>()
    for (i in 0 until count) {
        val value = if (mode == "boundary" && i == 0) 2000.0 else pattern[i % pattern.size]
        val end = time + value / 1000
        var row = PhysiologyQuality.IntervalObservation(originalId = "i$i", deviceId = deviceId, deviceFirmware = firmware,
            source = if (mode == "source_switch" && i >= 150) "other" else "test", modality = if (mode == "sdnn") "sdnn" else "ecg_nn",
            eventTime = time, originalRRMs = value, startBeatId = if (mode == "legacy") null else "b$i",
            endBeatId = if (mode == "legacy") null else "b${i + 1}", continuityGroup = if (mode == "legacy") null else "run",
            verifiedSpan = if (mode in listOf("legacy", "packet")) null else PhysiologyQuality.Span(time, end),
            timestampPrecisionSeconds = 0.001, decoderVersion = "fixture-v1", clockVersion = "verified-fixture-v1", ordinal = i)
        if (mode == "rejected_beat" && i == 149) row = row.copy(endBeatAccepted = false)
        if (mode == "corrected" && i == 150) row = row.copy(correctedRRMs = 1200.0, corrections = listOf(
            PhysiologyQuality.Correction("edit", "p1", "replaced"), PhysiologyQuality.Correction("edit", "p2", "replaced")))
        if (mode == "many_corrections" && i < 31) row = row.copy(corrections = listOf(PhysiologyQuality.Correction("edit", "p1", "replaced")))
        if (mode != "hole" || i != 150) rows.add(row)
        time = end
    }
    return if (mode == "duplicate") rows + rows else rows
}

class HrvWindowTest {
    @Test fun sharedGoldenWindows() {
        val data = javaClass.classLoader!!.getResourceAsStream("hrv_window_oracle.json")!!.bufferedReader().use { it.readText() }
        val cases = JSONObject(data).getJSONArray("cases")
        for (index in 0 until cases.length()) {
            val c = cases.getJSONObject(index); val id = c.getString("id"); val pattern = c.getJSONArray("pattern")
            val rows = hrvEvidence(count = c.getInt("count"), pattern = (0 until pattern.length()).map { pattern.getDouble(it) },
                offset = c.optDouble("offset", 0.0), mode = c.optString("mode", ""))
            val context = if (c.optString("context") == "mixed") listOf(
                PhysiologyQuality.ContextEpoch(0.0, 150.0, "sleep", true), PhysiologyQuality.ContextEpoch(150.0, 300.0, "active", true)
            ) else listOf(PhysiologyQuality.ContextEpoch(0.0, 300.0, c.optString("context", "sleep"), true))
            val r = HrvWindow.measure(0, rows, context, inputRevision = "golden")
            val reason = if (c.has("reason")) c.getString("reason") else null
            assertEquals(id, reason, r.reason); assertEquals(id, reason == null, r.measurementValid)
            assertEquals(id, c.getBoolean("baseline"), r.baselineEligible); assertEquals(id, c.getInt("pairs"), r.validPairCount)
            assertEquals(id, c.getDouble("coverage"), r.observedTimeFraction, 1e-9)
            assertEquals(id, c.getDouble("gap"), r.maximumGapSeconds, 1e-9)
            if (c.has("rmssd")) assertEquals(id, c.getDouble("rmssd"), r.observedRMSSD!!, 1e-9) else assertNull(id, r.observedRMSSD)
            if (c.has("sdnn")) assertEquals(id, c.getDouble("sdnn"), r.sdnn!!, 1e-9)
            if (c.has("corrected")) {
                assertEquals(id, c.getDouble("corrected"), r.correctedRMSSD!!, 1e-9)
                assertEquals(2, r.correctionEventCount); assertEquals(1 / 300.0, r.correctionFraction, 1e-12)
            } else assertNull(id, r.correctedRMSSD)
            assertEquals(id, r, HrvWindow.measure(0, rows.reversed(), context, inputRevision = "golden"))
        }
    }
    @Test fun conflictingReplayNeverChoosesArrivalOrder() {
        val rows = hrvEvidence(); val conflict = rows.first().copy(originalAccepted = false)
        val a = HrvWindow.measure(0, rows + conflict)
        assertEquals("original_identity_conflict", a.reason)
        assertEquals(a, HrvWindow.measure(0, (listOf(conflict) + rows).reversed())); assertNull(a.researchObservedRMSSD)
    }
    @Test fun threeAcceptedBeatsAndGapAreRequired() {
        val rows = hrvEvidence().mapIndexed { i, r -> if (i == 150) r.copy(originalAccepted = false) else r }
        val result = HrvWindow.measure(0, rows)
        assertFalse(result.pairMask[150]); assertFalse(result.pairMask[151]); assertEquals(297, result.validPairCount)
        val gap = HrvWindow.measure(0, rows.filter { it.eventTime < 100 || it.eventTime >= 120 },
            policy = HrvWindow.Policy(minimumObservedFraction = 0.8, maximumGapSeconds = 10.0))
        assertEquals("acquisition_gap", gap.reason); assertEquals(20.0, gap.maximumGapSeconds, 1e-9)
    }
    @Test fun packetAdapterDoesNotInventCoverageOrBridgeRemovedWords() {
        val parsed = mapOf("hist_version" to 18, "unix" to 1700000000, "rr_source_channel" to 5,
            "rr_count" to 2, "rr_intervals" to listOf(1000, 500), "rr_raw_ticks" to listOf(1024, 512))
        val frame = ParsedFrame(true, true, "HISTORICAL_DATA", parsed)
        val rows = PhysiologyQuality.historicalPacket(frame, "verified-packet-hash", "d")
        assertEquals(listOf(1000.0, 500.0), rows.map { it.originalRRMs })
        assertEquals(rows[0].endBeatId, rows[1].startBeatId); assertTrue(rows.all { it.verifiedSpan == null })
        val result = HrvWindow.measure(HrvWindow.alignedStart(rows[0].eventTime.toInt()), rows)
        assertEquals("timing_coverage_unverified", result.reason); assertEquals(1, result.validPairCount)
        assertTrue(PhysiologyQuality.historicalPacket(frame.copy(parsed = parsed + ("rr_count" to 3)), "zero-word-packet", "d").isEmpty())
        assertTrue(PhysiologyQuality.historicalPacket(frame.copy(crcOk = false), "bad-crc", "d").isEmpty())
    }
    @Test fun firmwareSwitchAndMissingProvenanceFailClosed() {
        val rows = hrvEvidence()
        val switched = rows.take(150) + hrvEvidence(firmware = "test-v2").takeLast(150)
        assertEquals("acquisition_version_switch", HrvWindow.measure(0, switched).reason)
        assertEquals("missing_correction_provenance", HrvWindow.measure(0, rows.mapIndexed { i, r -> if (i == 4) r.copy(correctedRRMs = 900.0) else r }).reason)
        assertEquals("invalid_quality_policy", HrvWindow.measure(0, rows, policy = HrvWindow.Policy(minimumObservedFraction = Double.NaN)).reason)
        assertEquals(-300, HrvWindow.alignedStart(-1))
    }
    @Test fun manyShortIntervalsCannotHideOneUninterpretableLongSpan() {
        val long = PhysiologyQuality.IntervalObservation(originalId = "long", deviceId = "d", deviceFirmware = "test-v1", source = "test", modality = "ecg_nn",
            eventTime = 100.0, originalRRMs = 200000.0, startBeatId = "b100", endBeatId = "b101", continuityGroup = "run",
            verifiedSpan = PhysiologyQuality.Span(100.0, 300.0), timestampPrecisionSeconds = 0.001, decoderVersion = "fixture-v1", clockVersion = "verified-fixture-v1")
        val r = HrvWindow.measure(0, hrvEvidence(count = 100) + long)
        assertEquals(1.0, r.observedTimeFraction, 1e-9); assertTrue(r.validIntervalFraction > 0.9)
        assertEquals("insufficient_accepted_duration", r.reason); assertNull(r.observedRMSSD)
    }

    @Test fun verifiedTimingCannotInflateCoverageUsingCoarsePrecision() {
        fun rows(count: Int = 300, duration: Double = 1.0, precision: Double) = (0 until count).map { i ->
            PhysiologyQuality.IntervalObservation(originalId = "i$i", deviceId = "d", source = "test", eventTime = i * duration,
                originalRRMs = 1000.0, startBeatId = "b$i", endBeatId = "b${i+1}", continuityGroup = "run",
                verifiedSpan = PhysiologyQuality.Span(i * duration, (i+1) * duration), timestampPrecisionSeconds = precision,
                decoderVersion = "fixture-v1", clockVersion = "verified-fixture-v1")
        }
        for (evidence in listOf(rows(60, 5.0, 5.0), rows(precision = 1.0), rows(duration = 1.003, precision = 0.020))) {
            val result = HrvWindow.measure(0, evidence)
            assertEquals("invalid_timing_metadata", result.reason)
            assertFalse(result.measurementValid); assertNull(result.observedRMSSD)
            assertEquals(0.0, result.observedTimeFraction, 0.0); assertEquals(0.0, result.acceptedDurationSeconds, 0.0)
        }
        assertTrue(HrvWindow.measure(0, rows(precision = 0.020)).measurementValid)
        assertTrue(HrvWindow.measure(0, rows(duration = 1.002, precision = 0.020)).measurementValid)
        assertEquals("engineering-shadow-90-v2", HrvWindow.Policy().version)
    }
}
