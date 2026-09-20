package com.noop.push

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PpgIdentityBinaryTest {
    private fun hex(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun sharedOraclePreservesMultipleRecordsAndUnsignedIdentity() {
        val fixture = javaClass.getResourceAsStream("/ppg_identity_binary_oracle.json")!!
            .bufferedReader().use { JSONObject(it.readText()) }
        val rows = fixture.getJSONArray("rows")
        val records = (0 until rows.length()).map {
            val row = rows.getJSONObject(it)
            PushPpgWaveformRecord(row.getLong("rowId"), row.getLong("ts"),
                if (row.isNull("burstIndex")) null else row.getInt("burstIndex"), hex(row.getString("samples")),
                if (row.isNull("recordIndex")) null else row.getLong("recordIndex"))
        }
        val bytes = PushBinaryCodec.pack(PushBinaryTable.PPG_WAVEFORM_SAMPLE, records.map(PushBinaryRow::PpgWaveform))
        assertArrayEquals(hex(fixture.getString("hex")), bytes)
        assertEquals(records, PushBinaryCodec.unpackPpgRecords(bytes))
        assertNotEquals(PushProtocol.binaryKeyFingerprint(PushBinaryTable.PPG_WAVEFORM_SAMPLE, "d", PushBinaryRow.PpgWaveform(records[0])),
            PushProtocol.binaryKeyFingerprint(PushBinaryTable.PPG_WAVEFORM_SAMPLE, "d", PushBinaryRow.PpgWaveform(records[1])))
        for (size in bytes.indices) assertThrows(PushProtocolException::class.java) {
            PushBinaryCodec.unpackPpgRecords(bytes.copyOf(size))
        }
        assertThrows(PushProtocolException::class.java) { PushBinaryCodec.unpackPpgRecords(bytes + byteArrayOf(0)) }
    }

    @Test fun legacyV1StillDecodesAndRetainsOriginalBytes() {
        val bytes = hex("4e5042310101010000000500000000000000320000000000000000010000000a")
        val rows = PushBinaryCodec.unpackPpgRecords(bytes)
        assertNull(rows.single().recordIndex)
        assertArrayEquals(bytes, PushBinaryCodec.pack(PushBinaryTable.PPG_WAVEFORM_SAMPLE, rows.map(PushBinaryRow::PpgWaveform)))
    }
}
