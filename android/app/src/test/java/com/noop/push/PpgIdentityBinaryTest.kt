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
        val bytes = PushBinaryCodec.pack(
            PushBinaryTable.PPG_WAVEFORM_SAMPLE,
            records.map(PushBinaryRow::PpgWaveform),
            ppgIdentityV2 = true,
        )
        assertArrayEquals(hex(fixture.getString("hex")), bytes)
        assertEquals(PushBinaryCodec.packedHeaderSize(PushBinaryTable.PPG_WAVEFORM_SAMPLE) +
            records.sumOf { PushBinaryCodec.packedRowSize(PushBinaryRow.PpgWaveform(it), ppgIdentityV2 = true) }, bytes.size)
        assertNotEquals(PushProtocol.binaryKeyFingerprint(PushBinaryTable.PPG_WAVEFORM_SAMPLE, "d", PushBinaryRow.PpgWaveform(records[0])),
            PushProtocol.binaryKeyFingerprint(PushBinaryTable.PPG_WAVEFORM_SAMPLE, "d", PushBinaryRow.PpgWaveform(records[1])))
        assertThrows(PushProtocolException::class.java) {
            PushBinaryCodec.pack(PushBinaryTable.PPG_WAVEFORM_SAMPLE, records.map(PushBinaryRow::PpgWaveform))
        }
    }

    @Test fun legacyV1RetainsOriginalWireBytesWithoutInventedIdentity() {
        val bytes = hex("4e5042310101010000000500000000000000320000000000000000010000000a")
        val record = PushPpgWaveformRecord(rowId = 5, ts = 50, burstIndex = null, samples = byteArrayOf(10))
        assertNull(record.recordIndex)
        assertArrayEquals(bytes, PushBinaryCodec.pack(PushBinaryTable.PPG_WAVEFORM_SAMPLE,
            listOf(PushBinaryRow.PpgWaveform(record))))
    }

    @Test fun encoderRejectsRecordIndicesOutsideUnsigned32BitDomain() {
        for (index in listOf(-1L, 4_294_967_296L)) {
            val record = PushPpgWaveformRecord(1, 100, null, byteArrayOf(1, 0), index)
            assertThrows(PushProtocolException::class.java) {
                PushBinaryCodec.pack(PushBinaryTable.PPG_WAVEFORM_SAMPLE,
                    listOf(PushBinaryRow.PpgWaveform(record)), ppgIdentityV2 = true)
            }
        }
    }
}
