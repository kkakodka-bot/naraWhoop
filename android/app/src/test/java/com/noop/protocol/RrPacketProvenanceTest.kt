package com.noop.protocol

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class RrPacketProvenanceTest {
    @Test fun sharedPacketIdentityAndZeroPositionsSurviveActualDecode() {
        val cases = JSONObject(javaClass.classLoader!!.getResourceAsStream("rr_packet_provenance_oracle.json")!!.bufferedReader().readText()).getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i); val bytes = RrPacketProvenance.bytes(c.getString("hex"))!!
            val packet = RrPacketProvenance.checked(bytes)!!
            fun ints(key: String) = c.getJSONArray(key).let { a -> (0 until a.length()).map { a.getInt(it) } }
            assertEquals(c.getString("packetId"), packet.packetId)
            assertEquals(ints("wordIndices"), packet.words().map { it.index })
            assertEquals(ints("rawTicks"), packet.words().map { it.rawTicks })
            assertEquals(ints("rrMs"), packet.words().map { it.rrMs })
            assertEquals(listOf(packet), extractHistoricalStreams(listOf(bytes), 0, 0, DeviceFamily.WHOOP5).rrPackets)
            val header = bytes.copyOf(); header[4] = (header[4].toInt() xor 1).toByte()
            val crc = Crc.crc16Modbus(header, 0, 6); header[6] = crc.toByte(); header[7] = (crc shr 8).toByte()
            assertEquals(packet.packetId, RrPacketProvenance.checked(header)!!.packetId)
            val corrupt = bytes.copyOf(); corrupt[24] = (corrupt[24].toInt() xor 1).toByte()
            assertNull(RrPacketProvenance.checked(corrupt))
            val remapped = RrPacketProvenance.checked(bytes, packet.ts + 300)!!
            assertEquals(packet.packetId, remapped.packetId); assertEquals(packet.sensorTs, remapped.sensorTs)
            assertEquals(300.0, remapped.timestampPrecisionSeconds, 0.0)
        }
    }
}
