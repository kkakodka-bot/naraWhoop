package com.noop.push

import org.junit.Assert.*
import org.junit.Test
import org.json.JSONObject

class RrPacketAppendTest {
    @Test fun versionedCompanionRetainsRawBytesAndIdentity() {
        val p = com.noop.protocol.RrPacketProvenance.checked(com.noop.protocol.RrPacketProvenance.bytes(
            "aa011a00010023592f12000000000000f153650000003c03000400000002c74eaa5b")!!)!!
        val row = PushAppendRecord(1, linkedMapOf("packetId" to p.packetId), linkedMapOf(
            "ts" to p.ts, "sensorTs" to p.sensorTs, "recordIndex" to p.recordIndex, "rawHex" to p.rawHex,
            "srcChannel" to p.srcChannel, "schemaVersion" to p.schemaVersion, "decoderVersion" to p.decoderVersion,
            "clockVersion" to p.clockVersion, "timestampPrecisionSeconds" to p.timestampPrecisionSeconds,
            "clockOffsetSeconds" to p.clockOffsetSeconds, "declaredCount" to p.declaredCount))
        val batch = PushProtocol.appendBatch(PushAppendTable.RR_PACKET_PROVENANCE,
            "3a3486dd-5030-4e17-a00d-a781399890f9", "d", null, listOf(row))
        val lines = batch.body.toString(Charsets.UTF_8).trim().lines()
        assertEquals("1.1", batch.protocolVersion); assertEquals("1.1", JSONObject(lines[0]).getString("protocolVersion"))
        assertEquals(p.packetId, JSONObject(lines[1]).getJSONObject("key").getString("packetId"))
        assertEquals(p.rawHex, JSONObject(lines[1]).getJSONObject("data").getString("rawHex"))
    }
}
