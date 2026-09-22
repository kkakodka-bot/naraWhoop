package com.noop.push

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PpgIdentityBinaryTest {
    // Independent fixture reader: production only encodes this wire format. Keep the oracle test
    // self-contained instead of referring to a decoder that was never part of the merged client.
    private fun PushBinaryCodec.unpackPpgRecords(bytes: ByteArray): List<PushPpgWaveformRecord> {
        try {
            val input = java.nio.ByteBuffer.wrap(bytes).order(java.nio.ByteOrder.LITTLE_ENDIAN)
            val magic = ByteArray(4).also(input::get)
            check(magic.contentEquals(MAGIC))
            val version = input.get().toInt(); check(version in 1..2)
            check(input.get().toInt() == 1)
            val count = input.int; check(count in 1..100_000)
            fun nullableIndex(): Long? = when (input.get().toInt()) {
                0 -> null
                1 -> input.long.also { check(it in 0..4294967295L) }
                else -> error("flag")
            }
            val result = List(count) {
                val row = input.long; val ts = input.long
                val record = if (version == 2) nullableIndex() else null
                val burst = when (input.get().toInt()) { 0 -> null; 1 -> input.int; else -> error("flag") }
                val size = input.int; check(size in 0..input.remaining())
                val samples = ByteArray(size).also(input::get)
                PushPpgWaveformRecord(row, ts, burst, samples, record)
            }
            check(!input.hasRemaining())
            return result
        } catch (_: Exception) { throw PushProtocolException("invalid fixture payload") }
    }
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
