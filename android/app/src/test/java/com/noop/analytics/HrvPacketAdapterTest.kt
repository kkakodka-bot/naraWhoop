package com.noop.analytics

import com.noop.data.RrInterval
import com.noop.protocol.RrPacketProvenance
import org.junit.Assert.*
import org.junit.Test

class HrvPacketAdapterTest {
    @Test fun nativePacketAdapterRetainsZeroAndDoesNotBorrowOtherTransport() {
        val p = RrPacketProvenance.checked(RrPacketProvenance.bytes("aa011a00010023592f12000000000000f153650000003c03000400000002c74eaa5b")!!)!!
        val legacy = listOf(RrInterval("d",p.ts,1000,srcChannel=5), RrInterval("d",p.ts+1,800,srcChannel=5),
            RrInterval("d",p.ts+2,900,srcChannel=7))
        val observations = PhysiologyQuality.packetOrLegacy(listOf(p),legacy,"d","u")!!
        assertEquals(4,observations.size); assertEquals(listOf(0,1,2),observations.take(3).map { it.ordinal })
        assertFalse(observations[1].originalAccepted)
        assertTrue(observations.all { it.userId == "u" && it.source == "whoop5_history" && it.verifiedSpan == null && it.deviceFirmware == null })
        assertNull(observations.last().startBeatId)
        val result = HrvWindow.measure(HrvWindow.alignedStart(p.ts.toInt()),observations.take(3))
        assertEquals(0,result.validPairCount); assertEquals("timing_coverage_unverified",result.reason)
        assertNull(result.observedRMSSD)
        assertNull(PhysiologyQuality.packetOrLegacy(emptyList(),legacy,"d"))
    }
}
