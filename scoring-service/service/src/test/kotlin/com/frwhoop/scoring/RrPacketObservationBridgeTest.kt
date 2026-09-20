package com.frwhoop.scoring

import com.frwhoop.scoring.db.RrPacketObservationBridge
import com.noop.analytics.HrvWindow
import com.noop.data.RrInterval
import com.noop.protocol.DeviceFamily
import com.noop.protocol.RrPacketProvenance
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class RrPacketObservationBridgeTest {
    @Test fun sharedRetainedBytesKeepZeroSlotAndNeverClaimTimedCoverage() {
        val cases = JSONObject(javaClass.getResource("/rr_packet_provenance_oracle.json")!!.readText()).getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i); val p = RrPacketProvenance.checked(RrPacketProvenance.bytes(c.getString("hex"))!!)!!
            assertEquals(c.getString("packetId"), p.packetId)
            val legacy = listOf(RrInterval("d",p.ts,1000,srcChannel=5), RrInterval("d",p.ts+1,1100,srcChannel=7))
            val rows = RrPacketObservationBridge.observations(listOf(p,p),legacy,DeviceFamily.WHOOP5,"u","d","fw")!!
            val packetRows = rows.filter { it.packetId == p.packetId }
            assertEquals(p.declaredCount, packetRows.size)
            assertEquals((0 until p.declaredCount).toList(), packetRows.map { it.ordinal })
            assertEquals(1, rows.count { it.source == "channel:7" && it.startBeatId == null })
            assertTrue(rows.all { it.verifiedSpan == null && it.userId == "u" })
            assertTrue(rows.all { it.deviceFirmware == null })
            val measured = HrvWindow.measure(HrvWindow.alignedStart(p.ts.toInt()),packetRows)
            assertEquals("timing_coverage_unverified", measured.reason); assertNull(measured.observedRMSSD)
            assertEquals(0, measured.validPairCount)
            val mixed = HrvWindow.measure(HrvWindow.alignedStart(p.ts.toInt()),rows)
            assertEquals("source_switch", mixed.reason); assertNull(mixed.observedRMSSD)
            assertNull(RrPacketObservationBridge.verified(p.copy(packetId="0".repeat(64))))
            assertNull(RrPacketObservationBridge.verified(p.copy(schemaVersion=99)))
            assertNull(RrPacketObservationBridge.observations(listOf(p),legacy,DeviceFamily.WHOOP4,"u","d",null))
        }
    }
}
