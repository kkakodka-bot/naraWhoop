package com.frwhoop.scoring

import com.frwhoop.scoring.scoring.HrvPayloadCodec
import com.noop.analytics.HrvWindow
import com.noop.analytics.PhysiologyQuality
import org.junit.Assert.*
import org.junit.Test

class HrvPayloadCodecTest {
    private val start=1_800_000_000
    private val owner="00000000-0000-4000-8000-000000000001"
    private val device="00000000-0000-4000-8000-000000000002"
    private fun window()=HrvWindow.measure(start,(0 until 300).map { i ->
        PhysiologyQuality.IntervalObservation("i$i",owner,device,source="synthetic_ecg",modality="ecg_nn",
            eventTime=start+i+0.5,originalRRMs=1000.0,startBeatId="b$i",endBeatId="b${i+1}",continuityGroup="capture",
            verifiedSpan=PhysiologyQuality.Span(start+i.toDouble(),start+i+1.0),timestampPrecisionSeconds=0.001,
            decoderVersion="synthetic-ecg-test-v1",clockVersion="synchronized-fixture-v1")
    },listOf(PhysiologyQuality.ContextEpoch(start.toDouble(),start+300.0,"sleep",true)),inputRevision="7")

    @Test fun zeroAndAllProvenanceRoundTripWithoutRenamingSdnn() {
        val input=window()
        assertTrue(input.measurementValid)
        val encoded=HrvPayloadCodec.encode(input,owner,device)
        assertEquals(0.0,encoded.getDouble("observed_rmssd_ms"),0.0)
        assertEquals(0.0,encoded.getDouble("sdnn_ms"),0.0)
        assertEquals(input,HrvPayloadCodec.decode(encoded))
        assertEquals(encoded.getString("window_id"),HrvPayloadCodec.encode(input.copy(inputRevision="8"),owner,device).getString("window_id"))
    }
    @Test fun unavailableIsNullNotZeroAndInvalidOwnerFails() {
        val missing=HrvWindow.measure(start,emptyList())
        val encoded=HrvPayloadCodec.encode(missing,owner,device)
        assertTrue(encoded.isNull("observed_rmssd_ms"));assertFalse(encoded.getBoolean("measurement_valid"))
        assertEquals("no_observations",HrvPayloadCodec.decode(encoded).reason)
        try { HrvPayloadCodec.encode(window(),"another-owner",device);fail("owner must match") }
        catch(_: IllegalArgumentException) { }
    }
    @Test fun malformedDurationCannotBecomeBaselineEvidence() {
        val encoded=HrvPayloadCodec.encode(window(),owner,device).put("end",start+301)
        try { HrvPayloadCodec.decode(encoded);fail("duration must be canonical") }
        catch(_: IllegalArgumentException) { }
    }
}
