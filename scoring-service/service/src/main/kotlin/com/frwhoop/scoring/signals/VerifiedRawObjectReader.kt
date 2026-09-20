package com.frwhoop.scoring.signals

import com.frwhoop.scoring.b2.B2ObjectStore
import com.github.luben.zstd.ZstdInputStream
import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.GZIPInputStream
import javax.sql.DataSource

/** Downloads and hashes bytes before decoding; catalogue claims are never signal evidence. */
class VerifiedRawObjectReader(private val objects: B2ObjectStore.GetClient) {
    // Keep raw storage at two bytes per signed count; List<Int> callers receive boxed values
    // only on access instead of retaining one heap object per waveform sample.
    private class SignedI16Columns(payload: ByteArray) : AbstractList<Int>(), RandomAccess {
        private val samples = ByteBuffer.wrap(payload).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().asReadOnlyBuffer()
        override val size: Int get() = samples.limit()
        override fun get(index: Int): Int = samples.get(index).toInt()
    }
    data class Manifest(
        val id: UUID, val userId: UUID, val deviceId: UUID, val key: String, val sha256: String,
        val compression: String, val format: String, val compressedBytes: Int, val uncompressedBytes: Int,
        val records: Int?, val start: Long, val end: Long,
    )
    data class Record(
        val rowId: Long, val timestamp: Long, val recordIndex: Long?, val burstIndex: Int?,
        val columns: List<Int>, val opaqueFields: ByteArray? = null,
    )
    data class Decoded(
        val manifest: Manifest, val kind: String, val records: List<Record>, val digest: String,
        val decoderVersion: String = VERSION,
        // NPB1 stores scalar timestamps and raw counts, not optical wavelength/clock calibration.
        val timingVerifiedForWaveforms: Boolean = false,
        val channelSemanticsVerified: Boolean = false,
        val unavailableReason: String = "waveform_timing_channel_and_units_require_acquisition_proof",
    )

    fun read(manifest: Manifest, userId: UUID, deviceId: UUID): Decoded {
        require(manifest.userId == userId && manifest.deviceId == deviceId) { "raw_owner_mismatch" }
        require(manifest.key.startsWith("v3/") && manifest.key.contains("/users/$userId/devices/$deviceId/")) { "raw_key_owner_mismatch" }
        require(manifest.sha256.matches(Regex("[0-9a-f]{64}"))) { "raw_digest_missing" }
        require(manifest.compressedBytes in 1..MAX_BYTES && manifest.uncompressedBytes in 1..MAX_BYTES) { "raw_size_limit" }
        require(manifest.end > manifest.start) { "raw_invalid_time_span" }
        val compressed = objects.getObject(manifest.key, manifest.compressedBytes)
        require(compressed.size == manifest.compressedBytes) { "raw_compressed_size_mismatch" }
        val stream = when (manifest.compression) {
            "gzip" -> GZIPInputStream(ByteArrayInputStream(compressed))
            "zstd" -> ZstdInputStream(ByteArrayInputStream(compressed))
            "none" -> ByteArrayInputStream(compressed)
            else -> error("raw_unsupported_compression")
        }
        val bytes = stream.use { it.readNBytes(manifest.uncompressedBytes + 1) }
        require(bytes.size == manifest.uncompressedBytes) { "raw_decoded_size_mismatch" }
        // Raw lane contentSha256 is defined over the uncompressed NPB1 payload, not transport bytes.
        val digest = B2ObjectStore.sha256Hex(bytes)
        require(MessageDigest.isEqual(digest.toByteArray(), manifest.sha256.toByteArray())) { "raw_digest_mismatch" }
        require(manifest.format in setOf("bin_gzip_noop_push_v1", "bin_zstd_noop_push_v1", "protobuf_zstd_noop_push_v1", "noop_push_npb1")) { "raw_unsupported_format" }
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun take(count: Int): ByteArray {
            require(count >= 0 && count <= buffer.remaining()) { "raw_truncated_record" }
            return ByteArray(count).also { buffer.get(it) }
        }
        fun blob(): ByteArray { require(buffer.remaining() >= 4) { "raw_truncated_blob_length" }; return take(buffer.int) }
        require(take(4).contentEquals("NPB1".toByteArray())) { "raw_bad_magic" }
        require(buffer.remaining() >= 6) { "raw_truncated_header" }
        val version = buffer.get().toInt() and 255; val kind = buffer.get().toInt() and 255
        require(version == 1 || version == 2 && kind == 1) { "raw_unsupported_version" }
        require(kind in setOf(1, 2, 4)) { "raw_unsupported_kind" }
        val count = buffer.int
        require(count in 1..MAX_RECORDS && (manifest.records == null || manifest.records == count)) { "raw_record_count_mismatch" }
        val records = (0 until count).map {
            require(buffer.remaining() >= 16) { "raw_truncated_record" }
            val rowId = buffer.long; val timestamp = buffer.long
            require(rowId > 0 && timestamp >= manifest.start && timestamp < manifest.end) { "raw_invalid_record_identity_or_time" }
            var burst: Int? = null; var index: Long? = null
            if (kind == 1) {
                require(buffer.remaining() >= 1) { "raw_truncated_ppg" }
                val hasBurst = buffer.get().toInt()
                require(hasBurst in 0..1) { "raw_invalid_burst_flag" }
                if (hasBurst == 1) { require(buffer.remaining() >= 4); burst = buffer.int }
                if (version == 2) {
                    require(buffer.remaining() >= 8); val rawIndex = buffer.long
                    require(rawIndex in -1..0xffffffffL) { "raw_invalid_record_index" }
                    index = rawIndex.takeIf { it >= 0 }
                }
            }
            val payload = blob()
            val columns = if (kind != 2) {
                require(payload.isNotEmpty() && payload.size % 2 == 0) { "raw_invalid_i16_payload" }
                if (kind == 4) require(payload.size == 1200) { "raw_invalid_imu_shape" }
                SignedI16Columns(payload)
            } else emptyList()
            Record(rowId, timestamp, index, burst, columns, if (kind == 2) payload else null)
        }
        require(!buffer.hasRemaining()) { "raw_trailing_bytes" }
        require(records.map { it.rowId }.distinct().size == count) { "raw_duplicate_row_identity" }
        if (kind == 1 && version == 2) require(records.filter { it.recordIndex != null }
            .map { it.timestamp to it.recordIndex }.distinct().size == records.count { it.recordIndex != null }) { "raw_duplicate_packet_identity" }
        return Decoded(manifest, when (kind) { 1 -> "ppg_i16_unqualified"; 4 -> "imu_6axis_i16_unqualified"; else -> "v18_aux_opaque" }, records, digest)
    }

    companion object {
        const val VERSION = "npb1-raw-decoder-2"
        const val MAX_BYTES = 64 * 1024 * 1024
        const val MAX_RECORDS = 100_000
    }
}

/** Owner-scoped discovery and conditional proof recording; a decode failure cannot bless an object. */
class RawSignalCatalogue(private val dataSource: DataSource, private val reader: VerifiedRawObjectReader) {
    fun discover(userId: UUID, deviceId: UUID, start: Long, end: Long): List<VerifiedRawObjectReader.Manifest> {
        require(end > start && end - start <= 76 * 3600) // Two local dates across DST or date-line travel.
        return dataSource.connection.use { connection -> connection.prepareStatement("""
            select distinct m.id, m.user_id, m.device_id, m.object_key, m.sha256, m.compression, m.format,
                m.compressed_bytes, m.uncompressed_bytes, m.sample_count, w.start_ts, w.end_ts
            from public.noop_signal_windows w join public.object_manifests m on m.id=w.object_id
            where w.user_id=? and w.device_id=? and m.user_id=w.user_id and m.device_id=w.device_id
              and m.object_key=w.object_key and w.start_ts<? and w.end_ts>? and w.interpolated_records=0
              and m.object_class in ('raw','waveform') and m.status in ('ready','verified')
            order by w.start_ts, m.id limit 256
        """.trimIndent()).use { query ->
            query.setObject(1, userId); query.setObject(2, deviceId); query.setLong(3, end); query.setLong(4, start)
            query.executeQuery().use { rows -> buildList {
                while (rows.next()) {
                    val compressed = rows.getLong("compressed_bytes"); val decoded = rows.getLong("uncompressed_bytes")
                    if (compressed !in 1..VerifiedRawObjectReader.MAX_BYTES || decoded !in 1..VerifiedRawObjectReader.MAX_BYTES) continue
                    val count = rows.getLong("sample_count"); val sampleCount = if (rows.wasNull()) null else count.takeIf { it in 1..100000 }?.toInt()
                    if (count > 100000) continue
                    add(VerifiedRawObjectReader.Manifest(rows.getObject("id", UUID::class.java), userId, deviceId,
                        rows.getString("object_key"), rows.getString("sha256") ?: "", rows.getString("compression") ?: "",
                        rows.getString("format") ?: "", compressed.toInt(), decoded.toInt(), sampleCount,
                        rows.getLong("start_ts"), rows.getLong("end_ts")))
                }
            } }
        } }
    }

    fun verify(manifest: VerifiedRawObjectReader.Manifest): VerifiedRawObjectReader.Decoded {
        val decoded = reader.read(manifest, manifest.userId, manifest.deviceId)
        dataSource.connection.use { connection -> connection.prepareStatement("""
            update public.object_manifests set sha256_source='server_verified',
                verified_at=case when sha256_source='server_verified' then coalesce(verified_at,now()) else now() end,
                decode_verified_at=case when sha256_source='server_verified' and decoder_version=?
                    then coalesce(decode_verified_at,now()) else now() end, decoder_version=?
            where id=? and user_id=? and device_id=? and object_key=? and sha256=?
              and compressed_bytes=? and uncompressed_bytes=? and status in ('ready','verified')
              and object_class in ('raw','waveform')
              and compression is not distinct from ? and format is not distinct from ?
              and sample_count is not distinct from ?
        """.trimIndent()).use { query ->
            query.setString(1, decoded.decoderVersion); query.setString(2, decoded.decoderVersion)
            query.setObject(3, manifest.id); query.setObject(4, manifest.userId)
            query.setObject(5, manifest.deviceId); query.setString(6, manifest.key); query.setString(7, decoded.digest)
            query.setInt(8, manifest.compressedBytes); query.setInt(9, manifest.uncompressedBytes)
            query.setString(10, manifest.compression); query.setString(11, manifest.format)
            if (manifest.records == null) query.setNull(12, java.sql.Types.BIGINT) else query.setLong(12, manifest.records.toLong())
            check(query.executeUpdate() == 1) { "raw_manifest_changed_during_read" }
        } }
        return decoded
    }
}
