package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.signals.VerifiedRawObjectReader
import com.github.luben.zstd.Zstd
import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.zip.GZIPOutputStream

class VerifiedRawObjectReaderTest {
    private val user = UUID.randomUUID(); private val device = UUID.randomUUID()
    private fun ppg(version: Int = 2, index: Long = 7): ByteArray = ByteBuffer.allocate(if (version == 2) 80 else 64)
        .order(ByteOrder.LITTLE_ENDIAN).apply {
            put("NPB1".toByteArray()); put(version.toByte()); put(1); putInt(2)
            for (i in 0..1) {
                putLong((i + 1).toLong()); putLong(1000); put(0)
                if (version == 2) putLong(index + i)
                putInt(6); putShort(0); putShort((-1).toShort()); putShort(32767)
            }
        }.array()
    private fun manifest(raw: ByteArray, encoded: ByteArray = raw, compression: String = "none") = VerifiedRawObjectReader.Manifest(
        UUID.randomUUID(), user, device, "v3/ppg/users/$user/devices/$device/ppgWaveformSample/2026/09/18/00/o.bin.gz",
        B2ObjectStore.sha256Hex(raw), compression, "bin_gzip_noop_push_v1", encoded.size, raw.size, 2, 1000, 1001)
    private fun reader(bytes: ByteArray) = VerifiedRawObjectReader(object : B2ObjectStore.GetClient {
        override fun getObject(key: String, maximumBytes: Int): ByteArray = bytes
    })
    private fun rejected(reason: String, operation: () -> Unit) {
        try { operation(); fail("Expected $reason") } catch (failure: IllegalArgumentException) { assertEquals(reason, failure.message) }
    }
    @Test fun gzipDigestUsesUncompressedContractAndPreservesSameSecondIdentity() {
        val raw = ppg(); val compressed = ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { it.write(raw) } }.toByteArray()
        val result = reader(compressed).read(manifest(raw, compressed, "gzip"), user, device)
        assertEquals(listOf(7L, 8L), result.records.map { it.recordIndex })
        assertEquals(listOf(0, -1, 32767), result.records[0].columns)
        assertFalse(result.channelSemanticsVerified); assertFalse(result.timingVerifiedForWaveforms)
    }
    @Test fun zstdAndLegacyDecodeWithoutInventedIndex() {
        val raw = ppg(1); val encoded = Zstd.compress(raw)
        val result = reader(encoded).read(manifest(raw, encoded, "zstd"), user, device)
        assertTrue(result.records.all { it.recordIndex == null })
    }
    @Test fun signedColumnViewPreservesEveryI16ValueAndIndependentIndexedAccess() {
        val count = 65536
        val raw = ByteBuffer.allocate(10 + 16 + 1 + 8 + 4 + count * 2).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("NPB1".toByteArray()); put(2); put(1); putInt(1)
            putLong(1); putLong(1000); put(0); putLong(7); putInt(count * 2)
            for (value in Short.MIN_VALUE.toInt()..Short.MAX_VALUE.toInt()) putShort(value.toShort())
        }.array()
        val columns = reader(raw).read(manifest(raw).copy(records = 1), user, device).records.single().columns
        assertEquals(count, columns.size)
        assertEquals(32767, columns.last())
        assertEquals(-32768, columns.first())
        assertEquals(0, columns[32768])
        assertEquals((-32768..32767).toList(), columns)
        try { columns[-1]; fail("negative sample index must fail") } catch (_: IndexOutOfBoundsException) { }
        try { columns[count]; fail("sample index past end must fail") } catch (_: IndexOutOfBoundsException) { }
    }
    @Test fun corruptionSizeOwnerAndTrailingBytesReject() {
        val raw = ppg(); val m = manifest(raw)
        rejected("raw_digest_mismatch") { reader(raw).read(m.copy(sha256 = "a".repeat(64)), user, device) }
        rejected("raw_owner_mismatch") { reader(raw).read(m, UUID.randomUUID(), device) }
        rejected("raw_compressed_size_mismatch") { reader(raw).read(m.copy(compressedBytes = raw.size + 1), user, device) }
        val extra = raw + byteArrayOf(1)
        rejected("raw_trailing_bytes") { reader(extra).read(manifest(extra), user, device) }
        rejected("raw_record_count_mismatch") { reader(raw).read(m.copy(records = 3), user, device) }
    }
    @Test fun decompressLimitRejectsBeforeDecode() {
        val raw = ppg(); val encoded = Zstd.compress(raw)
        rejected("raw_decoded_size_mismatch") {
            reader(encoded).read(manifest(raw, encoded, "zstd").copy(uncompressedBytes = raw.size - 1), user, device)
        }
    }
}
