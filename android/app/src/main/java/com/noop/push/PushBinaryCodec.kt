package com.noop.push

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/** Platform-neutral packed payload for `bin_gzip_noop_push_v1` / `protobuf_zstd_noop_push_v1`. */
object PushBinaryCodec {
    val MAGIC = "NPB1".toByteArray(Charsets.US_ASCII)
    const val FORMAT_VERSION: Byte = 1
    const val IMU_COLUMNS_PER_RECORD = 600
    const val IMU_RECORD_PAYLOAD_BYTES = IMU_COLUMNS_PER_RECORD * 2

    enum class Kind(val raw: Byte) {
        PPG_WAVEFORM_SAMPLE(1),
        V18_AUX_SAMPLE(2),
        RAW_BATCH(3),
        RAW_IMU_SESSION(4),
    }

    fun kind(table: PushBinaryTable): Kind = when (table) {
        PushBinaryTable.PPG_WAVEFORM_SAMPLE -> Kind.PPG_WAVEFORM_SAMPLE
        PushBinaryTable.V18_AUX_SAMPLE -> Kind.V18_AUX_SAMPLE
        PushBinaryTable.RAW_BATCH -> Kind.RAW_BATCH
        PushBinaryTable.RAW_IMU_SESSION -> Kind.RAW_IMU_SESSION
    }

    fun pack(table: PushBinaryTable, rows: List<PushBinaryRow>, ppgIdentityV2: Boolean = false, auxIdentityV2: Boolean = false): ByteArray {
        if (rows.isEmpty()) throw PushProtocolException("binary object must contain a row")
        return when (table) {
            PushBinaryTable.PPG_WAVEFORM_SAMPLE -> {
                val records = rows.map { row ->
                    when (row) {
                        is PushBinaryRow.PpgWaveform -> row.record
                        else -> throw PushProtocolException("binary row kind mismatch")
                    }
                }
                packPpgRecords(records, ppgIdentityV2)
            }
            PushBinaryTable.V18_AUX_SAMPLE -> {
                val records = rows.map { row ->
                    when (row) {
                        is PushBinaryRow.V18Aux -> row.record
                        else -> throw PushProtocolException("binary row kind mismatch")
                    }
                }
                packV18Records(records, auxIdentityV2)
            }
            PushBinaryTable.RAW_BATCH -> {
                if (rows.size != 1) throw PushProtocolException("rawBatch upload must contain exactly one batch row")
                when (val row = rows.single()) {
                    is PushBinaryRow.RawBatch -> packRawBatch(row.record)
                    else -> throw PushProtocolException("rawBatch upload must contain exactly one batch row")
                }
            }
            PushBinaryTable.RAW_IMU_SESSION -> {
                val records = rows.map { row ->
                    when (row) {
                        is PushBinaryRow.RawImuSession -> row.record
                        else -> throw PushProtocolException("binary row kind mismatch")
                    }
                }
                packImuRecords(records)
            }
        }
    }

    fun packedHeaderSize(table: PushBinaryTable): Int = when (table) {
        PushBinaryTable.RAW_BATCH -> 6
        PushBinaryTable.PPG_WAVEFORM_SAMPLE, PushBinaryTable.V18_AUX_SAMPLE, PushBinaryTable.RAW_IMU_SESSION -> 10
    }

    fun packedRowSize(row: PushBinaryRow, ppgIdentityV2: Boolean = false, auxIdentityV2: Boolean = false): Int = when (row) {
        is PushBinaryRow.PpgWaveform -> {
            val record = row.record
            8 + 8 + (if (ppgIdentityV2) (if (record.recordIndex == null) 1 else 9) else 0) + 1 + (if (record.burstIndex != null) 4 else 0) + 4 + record.samples.size
        }
        is PushBinaryRow.V18Aux -> 8 + 8 + (if (auxIdentityV2) (if (row.record.recordIndex == null) 1 else 9) else 0) + 4 + row.record.fields.size
        is PushBinaryRow.RawImuSession -> {
            if (row.record.columns.size != IMU_RECORD_PAYLOAD_BYTES) {
                throw PushProtocolException("rawImuSession record must carry $IMU_COLUMNS_PER_RECORD i16 columns")
            }
            8 + 8 + 4 + row.record.columns.size
        }
        is PushBinaryRow.RawBatch -> {
            val record = row.record
            2 + record.batchId.toByteArray(Charsets.UTF_8).size + 8 * 5 + 4 + 4 + 4 + record.framesBlob.size
        }
    }

    private fun packPpgRecords(records: List<PushPpgWaveformRecord>, identityV2: Boolean): ByteArray {
        if (!identityV2 && records.any { it.recordIndex != null }) throw PushProtocolException("PPG identity requires negotiated protocol 1.3")
        val out = ByteArrayOutputStream(records.size * 32 + 8)
        out.write(MAGIC); out.write(if (identityV2) 2 else 1); out.write(Kind.PPG_WAVEFORM_SAMPLE.raw.toInt())
        appendU32(records.size, out)
        for (record in records) {
            appendI64(record.rowId, out)
            appendI64(record.ts, out)
            if (identityV2) {
                val index = record.recordIndex
                if (index == null) out.write(0) else {
                    if (index !in 0..4294967295L) throw PushProtocolException("invalid PPG record index")
                    out.write(1); appendI64(index, out)
                }
            }
            if (record.burstIndex != null) {
                out.write(1)
                appendI32(record.burstIndex, out)
            } else {
                out.write(0)
            }
            appendBlob(record.samples, out)
        }
        return out.toByteArray()
    }

    private fun packV18Records(records: List<PushV18AuxRecord>, identityV2: Boolean): ByteArray {
        if (!identityV2 && records.any { it.recordIndex != null || com.noop.data.V18AuxIdentity.complete(it.fields)?.recordIndex != null })
            throw PushProtocolException("Auxiliary identity requires negotiated protocol 1.4")
        val out = ByteArrayOutputStream(records.size * 32 + 8)
        out.write(MAGIC); out.write(if (identityV2) 2 else 1); out.write(Kind.V18_AUX_SAMPLE.raw.toInt())
        appendU32(records.size, out)
        for (record in records) {
            appendI64(record.rowId, out)
            appendI64(record.ts, out)
            if (identityV2) {
                val complete = com.noop.data.V18AuxIdentity.complete(record.fields)
                    ?: throw PushProtocolException("Auxiliary fields require raw-archive validation")
                if (complete.recordIndex != record.recordIndex) throw PushProtocolException("Auxiliary envelope identity mismatch")
                if (record.recordIndex == null) out.write(0) else {
                    if (record.recordIndex !in 0..4294967295L) throw PushProtocolException("Invalid auxiliary index")
                    out.write(1); appendI64(record.recordIndex, out)
                }
            }
            appendBlob(record.fields, out)
        }
        return out.toByteArray()
    }

    private fun packRawBatch(record: PushRawBatchRecord): ByteArray {
        val out = ByteArrayOutputStream(record.framesBlob.size + 64)
        header(Kind.RAW_BATCH, out)
        appendUtf8(record.batchId, out)
        appendI64(record.capturedAt, out)
        appendI64(record.deviceClockRef, out)
        appendI64(record.wallClockRef, out)
        appendI64(record.startTs, out)
        appendI64(record.endTs, out)
        appendI32(record.frameCount, out)
        appendI32(record.byteSize, out)
        appendBlob(record.framesBlob, out)
        return out.toByteArray()
    }

    private fun packImuRecords(records: List<PushRawImuRecord>): ByteArray {
        val out = ByteArrayOutputStream(records.size * (IMU_RECORD_PAYLOAD_BYTES + 24) + 8)
        header(Kind.RAW_IMU_SESSION, out)
        appendU32(records.size, out)
        for (record in records) {
            if (record.columns.size != IMU_RECORD_PAYLOAD_BYTES) {
                throw PushProtocolException("rawImuSession record must carry $IMU_COLUMNS_PER_RECORD i16 columns")
            }
            appendI64(record.rowId, out)
            appendI64(record.ts, out)
            appendBlob(record.columns, out)
        }
        return out.toByteArray()
    }

    private fun header(kind: Kind, out: ByteArrayOutputStream) {
        out.write(MAGIC)
        out.write(FORMAT_VERSION.toInt())
        out.write(kind.raw.toInt())
    }

    private fun appendBlob(blob: ByteArray, out: ByteArrayOutputStream) {
        if (blob.size > PushProtocol.MAX_BODY_BYTES) {
            throw PushProtocolException("binary blob exceeds decoded limit")
        }
        appendU32(blob.size, out)
        out.write(blob)
    }

    private fun appendUtf8(value: String, out: ByteArrayOutputStream) {
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.size > UShort.MAX_VALUE.toInt()) {
            throw PushProtocolException("binary string exceeds limit")
        }
        out.write(
            ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(bytes.size.toShort()).array(),
        )
        out.write(bytes)
    }

    private fun appendI32(value: Int, out: ByteArrayOutputStream) {
        out.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array())
    }

    private fun appendU32(value: Int, out: ByteArrayOutputStream) = appendI32(value, out)

    private fun appendI64(value: Long, out: ByteArrayOutputStream) {
        out.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(value).array())
    }

    fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
