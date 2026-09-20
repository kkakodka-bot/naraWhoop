package com.noop.push

import java.time.LocalDate
import java.time.ZoneId

sealed interface PushTable {
    val wireName: String
}

/** The complete v1 append registry. Database tables are never discovered reflectively. */
enum class PushAppendTable(override val wireName: String) : PushTable {
    HR_SAMPLE("hrSample"),
    RR_INTERVAL("rrInterval"),
    RR_PACKET_PROVENANCE("rrPacketProvenance"),
    STANDARD_HR_RECEIPT("standardHRReceipt"),
    EVENT("event"),
    BATTERY("battery"),
    SPO2_SAMPLE("spo2Sample"),
    SKIN_TEMP_SAMPLE("skinTempSample"),
    RESP_SAMPLE("respSample"),
    GRAVITY_SAMPLE("gravitySample");
}

enum class PushMutableTable(override val wireName: String) : PushTable {
    DAILY_METRIC("dailyMetric"),
    SLEEP_SESSION("sleepSession"),
    WORKOUT("workout"),
    JOURNAL("journal");
}

enum class PushBinaryTable(override val wireName: String) : PushTable {
    PPG_WAVEFORM_SAMPLE("ppgWaveformSample"),
    V18_AUX_SAMPLE("v18AuxSample"),
    RAW_BATCH("rawBatch"),
    RAW_IMU_SESSION("rawImuSession");

    val contentEncoding: String
        get() = when (this) {
            PPG_WAVEFORM_SAMPLE, V18_AUX_SAMPLE -> "gzip"
            RAW_BATCH, RAW_IMU_SESSION -> "zstd"
        }
}

data class PushPpgWaveformRecord(
    val rowId: Long,
    val ts: Long,
    val burstIndex: Int?,
    val samples: ByteArray,
    val recordIndex: Long? = null,
) {
    init {
        require(rowId > 0)
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PushPpgWaveformRecord) return false
        return rowId == other.rowId && ts == other.ts && burstIndex == other.burstIndex &&
            samples.contentEquals(other.samples) && recordIndex == other.recordIndex
    }

    override fun hashCode(): Int {
        var result = rowId.hashCode()
        result = 31 * result + ts.hashCode()
        result = 31 * result + (burstIndex ?: 0)
        result = 31 * result + samples.contentHashCode()
        result = 31 * result + (recordIndex?.hashCode() ?: 0)
        return result
    }
}

data class PushV18AuxRecord(
    val rowId: Long,
    val ts: Long,
    val fields: ByteArray,
) {
    init {
        require(rowId > 0)
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PushV18AuxRecord) return false
        return rowId == other.rowId && ts == other.ts && fields.contentEquals(other.fields)
    }

    override fun hashCode(): Int {
        var result = rowId.hashCode()
        result = 31 * result + ts.hashCode()
        result = 31 * result + fields.contentHashCode()
        return result
    }
}

data class PushRawBatchRecord(
    val rowId: Long,
    val batchId: String,
    val capturedAt: Long,
    val deviceClockRef: Long,
    val wallClockRef: Long,
    val startTs: Long,
    val endTs: Long,
    val frameCount: Int,
    val byteSize: Int,
    val framesBlob: ByteArray,
) {
    init {
        require(rowId > 0)
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PushRawBatchRecord) return false
        return rowId == other.rowId && batchId == other.batchId && capturedAt == other.capturedAt &&
            deviceClockRef == other.deviceClockRef && wallClockRef == other.wallClockRef &&
            startTs == other.startTs && endTs == other.endTs && frameCount == other.frameCount &&
            byteSize == other.byteSize && framesBlob.contentEquals(other.framesBlob)
    }

    override fun hashCode(): Int {
        var result = rowId.hashCode()
        result = 31 * result + batchId.hashCode()
        result = 31 * result + capturedAt.hashCode()
        result = 31 * result + deviceClockRef.hashCode()
        result = 31 * result + wallClockRef.hashCode()
        result = 31 * result + startTs.hashCode()
        result = 31 * result + endTs.hashCode()
        result = 31 * result + frameCount
        result = 31 * result + byteSize
        result = 31 * result + framesBlob.contentHashCode()
        return result
    }
}

/** One second of 100 Hz six-axis IMU: 600 little-endian i16 columns. `rowId` mirrors `ts`. */
data class PushRawImuRecord(
    val rowId: Long,
    val ts: Long,
    val columns: ByteArray,
) {
    init {
        require(rowId > 0)
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PushRawImuRecord) return false
        return rowId == other.rowId && ts == other.ts && columns.contentEquals(other.columns)
    }

    override fun hashCode(): Int {
        var result = rowId.hashCode()
        result = 31 * result + ts.hashCode()
        result = 31 * result + columns.contentHashCode()
        return result
    }
}

sealed class PushBinaryRow {
    data class PpgWaveform(val record: PushPpgWaveformRecord) : PushBinaryRow()
    data class V18Aux(val record: PushV18AuxRecord) : PushBinaryRow()
    data class RawBatch(val record: PushRawBatchRecord) : PushBinaryRow()
    data class RawImuSession(val record: PushRawImuRecord) : PushBinaryRow()
}

data class PushBinaryBatch(
    val protocolVersion: String,
    val batchId: String,
    val sourceId: String,
    val table: PushBinaryTable,
    val deviceId: String,
    val objectId: String,
    val startTs: Long,
    val endTs: Long,
    val sampleCount: Int,
    val uncompressedBytes: Int,
    val contentSha256: String,
    val contentEncoding: String,
    val endCursor: PushCursor?,
    val manifestJSON: ByteArray,
    val payload: ByteArray,
) {
    val wireName: String get() = table.wireName
}

/** Key excludes deviceId (which is batch-scoped); data contains only non-key registry columns. */
data class PushAppendRecord(
    val rowId: Long,
    val key: Map<String, Any?>,
    val data: Map<String, Any?>,
) {
    init {
        require(rowId > 0) { "SQLite rowid must be positive" }
        require(key.isNotEmpty()) { "natural key must not be empty" }
    }
}

data class PushMutableRecord(
    val key: Map<String, Any?>,
    val data: Map<String, Any?>,
) {
    init {
        require(key.isNotEmpty()) { "natural key must not be empty" }
    }
}

data class PushWindow(
    val fromDay: String,
    val toDay: String,
    val startTsInclusive: Long,
    val endTsExclusive: Long,
) {
    companion object {
        fun ending(today: LocalDate, zoneId: ZoneId): PushWindow {
            val from = today.minusDays(13)
            return PushWindow(
                fromDay = from.toString(),
                toDay = today.toString(),
                startTsInclusive = from.atStartOfDay(zoneId).toEpochSecond(),
                endTsExclusive = today.plusDays(1).atStartOfDay(zoneId).toEpochSecond(),
            )
        }

        fun days(from: LocalDate, to: LocalDate, zoneId: ZoneId): PushWindow {
            require(!to.isBefore(from))
            return PushWindow(
                fromDay = from.toString(),
                toDay = to.toString(),
                startTsInclusive = from.atStartOfDay(zoneId).toEpochSecond(),
                endTsExclusive = to.plusDays(1).atStartOfDay(zoneId).toEpochSecond(),
            )
        }
    }
}

/** Persisted and transmitted cursor. The fingerprint is SHA-256, never raw key material. */
data class PushCursor(val rowId: Long, val naturalKeyFingerprint: String)

data class PushWindowProgress(
    val window: PushWindow,
    val batchId: String,
    /** Canonical SHA-256 per local calendar day; absent on pre-checksum installations. */
    val dayHashes: Map<String, String> = emptyMap(),
)

/** Fully materialized bounded request; no Room transaction survives into transport. */
data class PushBatch(
    val protocolVersion: String,
    val batchId: String,
    val sourceId: String,
    val table: PushTable,
    val deviceId: String,
    val mode: String,
    val startCursor: PushCursor?,
    val endCursor: PushCursor?,
    val recordCount: Int,
    val window: PushWindow?,
    val replacementId: String? = null,
    val part: Int? = null,
    val parts: Int? = null,
    val body: ByteArray,
)

data class PushTransportResponse(val statusCode: Int, val body: ByteArray)

/** Direct-to-bucket lane advertised at protocol 1.2. */
data class PushObjectLane(
    val endpoint: String,
    val maxObjectBytes: Long,
    val urlTtlSec: Long?,
    val streams: Set<PushBinaryTable>,
)

/** Intent body posted to the object lane; digest is over the UNCOMPRESSED NPB1 payload. */
data class PushObjectManifest(
    val protocolVersion: String,
    val batchId: String,
    val sourceId: String,
    val deviceId: String,
    val stream: String,
    val objectId: String,
    val startTs: Long,
    val endTs: Long,
    val sampleCount: Long,
    val uncompressedBytes: Long,
    val compressedBytes: Long,
    val contentSha256: String,
    val contentEncoding: String,
) {
    constructor(batch: PushBinaryBatch) : this(
        protocolVersion = batch.protocolVersion,
        batchId = batch.batchId,
        sourceId = batch.sourceId,
        deviceId = batch.deviceId,
        stream = batch.table.wireName,
        objectId = batch.objectId,
        startTs = batch.startTs,
        endTs = batch.endTs,
        sampleCount = batch.sampleCount.toLong(),
        uncompressedBytes = batch.uncompressedBytes.toLong(),
        compressedBytes = batch.payload.size.toLong(),
        contentSha256 = batch.contentSha256,
        contentEncoding = batch.contentEncoding,
    )

    fun replacingObjectId(newObjectId: String) = copy(objectId = newObjectId)

    fun encode(): ByteArray {
        val map = linkedMapOf<String, Any?>(
            "batchId" to batchId,
            "contentEncoding" to contentEncoding,
            "contentSha256" to contentSha256,
            "compressedBytes" to compressedBytes,
            "deviceId" to deviceId,
            "endTs" to endTs,
            "objectId" to objectId,
            "protocolVersion" to protocolVersion,
            "sampleCount" to sampleCount,
            "sourceId" to sourceId,
            "startTs" to startTs,
            "stream" to stream,
            "type" to "binaryObject",
            "uncompressedBytes" to uncompressedBytes,
        )
        return PushProtocol.canonicalJsonMap(map).toByteArray(Charsets.UTF_8)
    }
}

data class PushObjectIntent(
    val objectId: String,
    val objectKey: String,
    val uploadUrl: String?,
    val requiredHeaders: Map<String, String>,
    val expiresAt: String?,
    val duplicate: Boolean,
)

data class PushObjectAck(
    val objectId: String,
    val status: String,
    val objectKey: String,
    val duplicate: Boolean,
) {
    val releasesLocalRows: Boolean get() = status == "ready" || status == "verified"
}

data class PushInFlightObject(
    val objectId: String,
    val objectKey: String,
    val contentSha256: String,
    val uploaded: Boolean,
)

/** File-backed IMU records for rawImuSession (not a Room table). */
interface ImuSessionPushSource {
    fun pushDeviceIds(): Set<String>
    fun pushRecords(deviceId: String, afterTs: Long, limit: Int): List<ImuPushRecord>
}

data class ImuPushRecord(val ts: Long, val columns: ByteArray) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ImuPushRecord) return false
        return ts == other.ts && columns.contentEquals(other.columns)
    }

    override fun hashCode(): Int {
        var result = ts.hashCode()
        result = 31 * result + columns.contentHashCode()
        return result
    }
}

/** Bounded, machine-readable receiver diagnostic; arbitrary response text is never retained. */
data class PushError(val protocolVersion: String, val code: String) {
    companion object {
        private val SAFE_CODE = Regex("[a-z][a-z0-9_]{0,63}")

        /** Local stream identity wins; only allowlisted stage and UUID correlation are retained. */
        fun httpFailure(status: Int, bytes: ByteArray, expectedVersion: String = PushProtocol.VERSION,
                        table: PushTable? = null): PushFailure {
            val code = parseCode(bytes, expectedVersion)
            val obj = if (code == null) null else runCatching { org.json.JSONObject(bytes.toString(Charsets.UTF_8)) }.getOrNull()
            return PushFailure.http(status, code, stream = table?.wireName,
                stage = obj?.opt("stage") as? String, correlationId = obj?.opt("correlationId") as? String)
        }

        fun parseCode(bytes: ByteArray, expectedVersion: String = PushProtocol.VERSION): String? {
            if (bytes.isEmpty() || bytes.size > PushProtocol.MAX_ACK_BYTES) return null
            return runCatching {
                val obj = org.json.JSONObject(bytes.toString(Charsets.UTF_8))
                val code = obj.opt("code") as? String
                if (obj.opt("type") == "error" && obj.opt("protocolVersion") == expectedVersion &&
                    code != null && code.matches(SAFE_CODE)
                ) code else null
            }.getOrNull()
        }
    }
}

interface PushTransport {
    suspend fun capabilities(): PushCapabilitiesResult =
        PushCapabilitiesResult.Available(PushCapabilities.ALL)
    suspend fun post(batch: PushBatch): PushTransportResponse
    suspend fun postBinary(batch: PushBinaryBatch): PushTransportResponse =
        throw PushTransportException(PushFailure(PushFailureCode.LOCAL_DATA))
    suspend fun createObjectIntent(manifest: PushObjectManifest, lane: PushObjectLane): PushObjectIntent =
        throw PushTransportException(PushFailure(PushFailureCode.LOCAL_DATA))
    suspend fun uploadObject(intent: PushObjectIntent, body: ByteArray) {
        throw PushTransportException(PushFailure(PushFailureCode.LOCAL_DATA))
    }
    suspend fun completeObject(objectId: String, lane: PushObjectLane): PushObjectAck =
        throw PushTransportException(PushFailure(PushFailureCode.LOCAL_DATA))
}

interface PushProgressStore {
    suspend fun knownDeviceIds(): Set<String>
    suspend fun rememberDeviceId(deviceId: String)
    suspend fun cursor(table: PushAppendTable, deviceId: String): PushCursor?
    suspend fun saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor)
    suspend fun binaryCursor(table: PushBinaryTable, deviceId: String): PushCursor?
    suspend fun saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor)
    suspend fun window(table: PushMutableTable, deviceId: String): PushWindowProgress?
    suspend fun saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress)
    suspend fun inFlightObject(table: PushBinaryTable, deviceId: String): PushInFlightObject? = null
    suspend fun saveInFlightObject(table: PushBinaryTable, deviceId: String, inFlight: PushInFlightObject?) {}
}

/** All methods return bounded snapshots and close their database transaction before returning. */
interface PushSnapshotSource {
    suspend fun knownDeviceIds(capabilities: PushCapabilities = PushCapabilities.ALL): List<String>

    suspend fun appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Long): PushAppendRecord?

    suspend fun appendRows(
        table: PushAppendTable,
        deviceId: String,
        afterRowId: Long,
        limit: Int,
    ): List<PushAppendRecord>

    suspend fun mutableRows(
        table: PushMutableTable,
        deviceId: String,
        window: PushWindow,
        limit: Int,
    ): List<PushMutableRecord>

    suspend fun binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Long): PushBinaryRow?

    suspend fun binaryRows(
        table: PushBinaryTable,
        deviceId: String,
        afterRowId: Long,
        limit: Int,
    ): List<PushBinaryRow>

    suspend fun acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: List<PushBinaryRow>)
}

sealed interface PushResult {
    data class Accepted(
        val batchId: String,
        val recordCount: Int,
        val hasMore: Boolean,
        val batchCount: Int = 1,
    ) : PushResult

    data object NoData : PushResult

    data class Rejected(
        val reason: String,
        val retryable: Boolean,
        val failure: PushFailure? = null,
    ) : PushResult
}

data class PushRunResult(
    val acceptedBatches: Int,
    val rejectedBatches: Int,
    val hasMoreAppendRows: Boolean,
    val hasMoreBinaryRows: Boolean = false,
    val acceptedRecords: Int = 0,
    val hasRetryableFailure: Boolean = false,
    val nextDeviceIndex: Int = 0,
    val hasMoreDevices: Boolean = false,
    val failure: PushFailure? = null,
)
