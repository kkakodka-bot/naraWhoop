package com.noop.push

import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID

class PushProtocolException(message: String) : IllegalArgumentException(message)

/** Deterministic, bounded NDJSON encoder and acknowledgement codec for protocol 1.0. */
object PushProtocol {
    const val VERSION = "1.0"
    const val BINARY_VERSION = "1.1"
    const val OBJECT_VERSION = "1.2"
    /** Sender-preferred list for capability negotiation (`GET`); see PUSH_PROTOCOL.md. */
    const val CAPABILITIES_ACCEPT_VERSIONS = "1.4,1.3,1.2,1.1,1.0"
    const val MAX_RECORDS = 5_000
    /** Hard limit for the decoded UTF-8 NDJSON entity, before optional content coding. */
    const val MAX_BODY_BYTES = 4 * 1024 * 1024
    /** Deflate framing can be slightly larger than incompressible input; keep that copy bounded too. */
    const val MAX_WIRE_BODY_BYTES = MAX_BODY_BYTES + 64 * 1024
    const val MAX_ACK_BYTES = 16 * 1024
    internal const val SNAPSHOT_PAGE_SIZE = 5_000
    internal const val MAX_MUTABLE_SNAPSHOT_RECORDS = 1_000
    internal const val MAX_MUTABLE_SNAPSHOT_ENCODED_BYTES = 2 * 1024 * 1024
    const val MAX_OBJECT_DECODED_BYTES = 64 * 1024 * 1024
    const val MAX_OBJECT_WIRE_BYTES = 256 * 1024 * 1024 + 64 * 1024
    const val MAX_IMU_OBJECT_WINDOW_SECONDS = 3_600L
    internal val FORBIDDEN_REMOTE_CONTROL_MEMBERS = setOf(
        "command", "commands", "endpoint", "url", "cadence", "schema", "fields",
    )

    fun appendBatch(
        table: PushAppendTable,
        sourceId: String,
        deviceId: String,
        startCursor: PushCursor?,
        records: List<PushAppendRecord>,
        protocolVersion: String = VERSION,
    ): PushBatch {
        validateUuid(sourceId, "sourceId")
        val selectedVersion = if (table.isScalarExtension) protocolVersion else VERSION
        if (table.isScalarExtension && selectedVersion !in setOf("1.1", "1.2", "1.3", "1.4"))
            throw PushProtocolException("Scalar stream requires negotiated protocol 1.1 or later")
        if (records.isEmpty()) throw PushProtocolException("append batch must contain a record")
        require(records.zipWithNext().all { (a, b) -> a.rowId < b.rowId }) {
            "append records must be strictly ordered by rowid"
        }
        if (!table.isScalarExtension) records.forEach { validateRecord(table, it.key, it.data) }
        val candidates = records.take(MAX_RECORDS)
        val selectedRows = ArrayList<PushAppendRecord>(candidates.size)
        val selectedLines = ArrayList<ByteArray>(candidates.size)
        var rowBytes = 0
        for (i in candidates.indices) {
            val candidate = if (table.isScalarExtension) scalarRecord(table, candidates[i], selectedVersion) ?: break else candidates[i]
            // Encode one row at a time so rows beyond the decoded entity bound never create a
            // second page-sized collection of byte arrays in memory.
            val encodedRow = encodeRecordLine(candidate)
            val end = cursorFor(table, deviceId, candidate)
            val candidateCount = selectedRows.size + 1
            val headerSize = appendHeader(
                sourceId, table, deviceId, startCursor, end, candidateCount, UUID_PLACEHOLDER, selectedVersion,
            ).size
            if (headerSize + rowBytes + encodedRow.size > MAX_BODY_BYTES) break
            selectedRows += candidate
            selectedLines += encodedRow
            rowBytes += encodedRow.size
        }
        if (selectedRows.isEmpty()) throw PushProtocolException("first append record exceeds the 4 MiB decoded batch limit")

        val endCursor = cursorFor(table, deviceId, selectedRows.last())
        val identity = appendIdentity(sourceId, table, deviceId, startCursor, endCursor, selectedRows.size, selectedVersion)
        val batchId = stableUuid(identity, selectedLines)
        val header = appendHeader(sourceId, table, deviceId, startCursor, endCursor, selectedRows.size, batchId, selectedVersion)
        val body = concatenate(header, selectedLines)
        check(body.size <= MAX_BODY_BYTES)
        return PushBatch(
            protocolVersion = selectedVersion,
            batchId = batchId,
            sourceId = sourceId,
            table = table,
            deviceId = deviceId,
            mode = "append",
            startCursor = startCursor,
            endCursor = endCursor,
            recordCount = selectedRows.size,
            window = null,
            body = body,
        )
    }

    /** Builds every bounded part of one authoritative replacement. Empty snapshots produce one part. */
    fun mutableBatches(
        table: PushMutableTable,
        sourceId: String,
        deviceId: String,
        window: PushWindow,
        records: List<PushMutableRecord>,
    ): List<PushBatch> {
        validateUuid(sourceId, "sourceId")
        records.forEach { validateRecord(table, it.key, it.data) }
        val duplicate = records.groupingBy { orderedObjectJson(it.key) }.eachCount().any { it.value > 1 }
        if (duplicate) throw PushProtocolException("replace_window contains a duplicate key")
        val lines = records.map(::encodeRecordLine)
        val replacementIdentity = mapOf(
            "deviceId" to deviceId,
            "delivery" to "replace_window",
            "protocolVersion" to VERSION,
            "sourceId" to sourceId,
            "stream" to table.wireName,
            "window" to selectorBounds(table, window),
        )
        val replacementId = stableUuid(replacementIdentity, lines)

        val chunks = mutableListOf<MutableList<ByteArray>>()
        var current = mutableListOf<ByteArray>()
        var currentBytes = 0
        for (line in lines) {
            val nextCount = current.size + 1
            val conservativeHeader = mutableHeader(
                sourceId = sourceId,
                table = table,
                deviceId = deviceId,
                window = window,
                replacementId = replacementId,
                part = Int.MAX_VALUE,
                parts = Int.MAX_VALUE,
                count = nextCount,
                batchId = UUID_PLACEHOLDER,
            )
            if (nextCount > MAX_RECORDS || conservativeHeader.size + currentBytes + line.size > MAX_BODY_BYTES) {
                if (current.isEmpty()) throw PushProtocolException("first replace_window record exceeds the 4 MiB decoded batch limit")
                chunks += current
                current = mutableListOf()
                currentBytes = 0
            }
            val oneHeader = mutableHeader(
                sourceId, table, deviceId, window, replacementId,
                Int.MAX_VALUE, Int.MAX_VALUE, 1, UUID_PLACEHOLDER,
            )
            if (oneHeader.size + line.size > MAX_BODY_BYTES) {
                throw PushProtocolException("replace_window record exceeds the 4 MiB decoded batch limit")
            }
            current += line
            currentBytes += line.size
        }
        if (current.isNotEmpty() || chunks.isEmpty()) chunks += current

        val parts = chunks.size
        return chunks.mapIndexed { index, partLines ->
            val part = index + 1
            val identity = mutableIdentity(
                sourceId, table, deviceId, window, replacementId, part, parts, partLines.size,
            )
            val batchId = stableUuid(identity, partLines)
            val header = mutableHeader(
                sourceId, table, deviceId, window, replacementId, part, parts, partLines.size, batchId,
            )
            val body = concatenate(header, partLines)
            check(partLines.size <= MAX_RECORDS && body.size <= MAX_BODY_BYTES)
            PushBatch(
                protocolVersion = VERSION,
                batchId = batchId,
                sourceId = sourceId,
                table = table,
                deviceId = deviceId,
                mode = "replace_window",
                startCursor = null,
                endCursor = null,
                recordCount = partLines.size,
                window = window,
                replacementId = replacementId,
                part = part,
                parts = parts,
                body = body,
            )
        }
    }

    fun mutableBatch(
        table: PushMutableTable,
        sourceId: String,
        deviceId: String,
        window: PushWindow,
        records: List<PushMutableRecord>,
    ): PushBatch = mutableBatches(table, sourceId, deviceId, window, records).singleOrNull()
        ?: throw PushProtocolException("replace_window requires multiple parts")

    /** SHA-256(stream LF device LF compact-natural-key), matching cursor invalidation contract. */
    fun keyFingerprint(table: PushAppendTable, deviceId: String, key: Map<String, Any?>): String {
        validateRecordKeys(table, key)
        return sha256Hex("${table.wireName}\n$deviceId\n${orderedObjectJson(key)}".toByteArray(Charsets.UTF_8))
    }

    fun binaryKeyFingerprint(table: PushBinaryTable, deviceId: String, row: PushBinaryRow, auxIdentityV2: Boolean = false): String {
        val payload = when {
            table == PushBinaryTable.PPG_WAVEFORM_SAMPLE && row is PushBinaryRow.PpgWaveform ->
                row.record.recordIndex?.let { "ppgWaveformSample-v2\n$deviceId\n${row.record.ts}\n$it" }
                    ?: "ppgWaveformSample\n$deviceId\n${row.record.ts}\n${row.record.burstIndex ?: ""}"
            table == PushBinaryTable.V18_AUX_SAMPLE && row is PushBinaryRow.V18Aux ->
                if (auxIdentityV2) "v18AuxSample-v2\n$deviceId\n${row.record.ts}\n${row.record.recordIndex ?: "unknown"}"
                else "v18AuxSample\n$deviceId\n${row.record.ts}"
            table == PushBinaryTable.RAW_BATCH && row is PushBinaryRow.RawBatch ->
                "rawBatch\n$deviceId\n${row.record.batchId}"
            table == PushBinaryTable.RAW_IMU_SESSION && row is PushBinaryRow.RawImuSession ->
                "rawImuSession\n$deviceId\n${row.record.ts}"
            else -> throw PushProtocolException("binary row kind mismatch")
        }
        return sha256Hex(payload.toByteArray(Charsets.UTF_8))
    }

    fun binaryObjectBatch(
        table: PushBinaryTable,
        sourceId: String,
        deviceId: String,
        startCursor: PushCursor?,
        rows: List<PushBinaryRow>,
        protocolVersion: String = BINARY_VERSION,
        decodedLimit: Int = MAX_BODY_BYTES,
    ): PushBinaryBatch {
        validateUuid(sourceId, "sourceId")
        if (rows.isEmpty()) throw PushProtocolException("binary object must contain a row")

        val selected = when (table) {
            PushBinaryTable.RAW_BATCH -> {
                if (rows.size != 1) throw PushProtocolException("rawBatch upload must contain exactly one row")
                rows
            }
            PushBinaryTable.PPG_WAVEFORM_SAMPLE, PushBinaryTable.V18_AUX_SAMPLE, PushBinaryTable.RAW_IMU_SESSION ->
                selectBinaryRows(table, rows, decodedLimit, protocolVersion in setOf("1.3", "1.4"), protocolVersion == "1.4")
        }

        val decoded = PushBinaryCodec.pack(table, selected, protocolVersion in setOf("1.3", "1.4"), protocolVersion == "1.4")
        if (decoded.size > decodedLimit) {
            throw PushProtocolException("binary object exceeds the decoded limit")
        }
        val contentSha256 = PushBinaryCodec.sha256Hex(decoded)
        val contentEncoding = table.contentEncoding
        val payload = if (protocolVersion in setOf(OBJECT_VERSION, "1.3", "1.4")) {
            PushBinaryCompression.compressObject(decoded, contentEncoding)
        } else {
            PushBinaryCompression.compress(decoded, contentEncoding)
        }
        val (startTs, endTs, sampleCount) = binaryBounds(table, selected)
        val endCursor = binaryEndCursor(table, deviceId, selected, protocolVersion == "1.4")
        val identity = linkedMapOf<String, Any?>(
            "contentSha256" to contentSha256,
            "deviceId" to deviceId,
            "protocolVersion" to protocolVersion,
            "sampleCount" to sampleCount,
            "sourceId" to sourceId,
            "startTs" to startTs,
            "endTs" to endTs,
            "stream" to table.wireName,
            "type" to "binaryObject",
        )
        val batchId = stableUuid(identity, listOf(decoded))
        val objectId = stableUuid(identity + ("batchId" to batchId), listOf(decoded))
        val manifest = identity + mapOf(
            "batchId" to batchId,
            "objectId" to objectId,
            "uncompressedBytes" to decoded.size,
            "contentEncoding" to contentEncoding,
        )
        return PushBinaryBatch(
            protocolVersion = protocolVersion,
            batchId = batchId,
            sourceId = sourceId,
            table = table,
            deviceId = deviceId,
            objectId = objectId,
            startTs = startTs,
            endTs = endTs,
            sampleCount = sampleCount,
            uncompressedBytes = decoded.size,
            contentSha256 = contentSha256,
            contentEncoding = contentEncoding,
            endCursor = endCursor,
            manifestJSON = canonicalJsonMap(manifest).toByteArray(Charsets.UTF_8),
            payload = payload,
        )
    }

    fun freshObjectId(): String = java.util.UUID.randomUUID().toString()

    private fun selectBinaryRows(
        table: PushBinaryTable,
        rows: List<PushBinaryRow>,
        decodedLimit: Int,
        ppgIdentityV2: Boolean = false,
        auxIdentityV2: Boolean = false,
    ): List<PushBinaryRow> {
        val selected = ArrayList<PushBinaryRow>()
        var decodedBytes = PushBinaryCodec.packedHeaderSize(table)
        var windowStartTs: Long? = null
        var auxMin: Long? = null
        var auxMax: Long? = null
        var previousRowId: Long? = null
        for (row in rows.take(MAX_RECORDS)) {
            if (row is PushBinaryRow.V18Aux) {
                if (!auxIdentityV2 && row.record.recordIndex != null) break
                val ts = row.record.ts
                val min = minOf(auxMin ?: ts, ts); val max = maxOf(auxMax ?: ts, ts)
                if (ts <= 0 || ts == Long.MAX_VALUE || max - min >= 48 * 3600) break
                if (previousRowId != null && row.record.rowId <= previousRowId) throw PushProtocolException("Auxiliary rows must be a contiguous ordered prefix")
                auxMin = min; auxMax = max; previousRowId = row.record.rowId
            }
            if (table == PushBinaryTable.RAW_IMU_SESSION) {
                val record = (row as? PushBinaryRow.RawImuSession)?.record
                    ?: throw PushProtocolException("binary row kind mismatch")
                if (windowStartTs != null && record.ts - windowStartTs >= MAX_IMU_OBJECT_WINDOW_SECONDS) break
            }
            val rowSize = PushBinaryCodec.packedRowSize(row, ppgIdentityV2, auxIdentityV2)
            if (decodedBytes + rowSize > decodedLimit) break
            selected += row
            decodedBytes += rowSize
            if (table == PushBinaryTable.RAW_IMU_SESSION && windowStartTs == null) {
                windowStartTs = (row as PushBinaryRow.RawImuSession).record.ts
            }
        }
        if (selected.isEmpty()) throw PushProtocolException("first binary row exceeds the decoded batch limit")
        return selected
    }

    private fun binaryBounds(table: PushBinaryTable, rows: List<PushBinaryRow>): Triple<Long, Long, Int> = when (table) {
        PushBinaryTable.RAW_BATCH -> {
            val record = (rows.single() as PushBinaryRow.RawBatch).record
            Triple(record.startTs, record.endTs, record.frameCount)
        }
        PushBinaryTable.PPG_WAVEFORM_SAMPLE, PushBinaryTable.V18_AUX_SAMPLE, PushBinaryTable.RAW_IMU_SESSION -> {
            val timestamps = rows.map { row ->
                when (row) {
                    is PushBinaryRow.PpgWaveform -> row.record.ts
                    is PushBinaryRow.V18Aux -> row.record.ts
                    is PushBinaryRow.RawImuSession -> row.record.ts
                    else -> throw PushProtocolException("binary row kind mismatch")
                }
            }
            Triple(timestamps.minOrNull()!!, timestamps.maxOrNull()!! + 1, rows.size)
        }
    }

    private fun binaryEndCursor(table: PushBinaryTable, deviceId: String, rows: List<PushBinaryRow>, auxIdentityV2: Boolean = false): PushCursor? {
        when (table) {
            PushBinaryTable.RAW_BATCH -> return null
            PushBinaryTable.PPG_WAVEFORM_SAMPLE, PushBinaryTable.V18_AUX_SAMPLE, PushBinaryTable.RAW_IMU_SESSION -> {
                val last = rows.lastOrNull() ?: return null
                val rowId = when (last) {
                    is PushBinaryRow.PpgWaveform -> last.record.rowId
                    is PushBinaryRow.V18Aux -> last.record.rowId
                    is PushBinaryRow.RawImuSession -> last.record.rowId
                    else -> throw PushProtocolException("binary row kind mismatch")
                }
                return PushCursor(rowId, binaryKeyFingerprint(table, deviceId, last, auxIdentityV2))
            }
        }
    }

    internal fun mutableRecordEncodedSize(table: PushMutableTable, record: PushMutableRecord): Int {
        validateRecord(table, record.key, record.data)
        return encodeRecordLine(record).size
    }

    /** Stable local content identity. It is progress metadata and is never sent to the receiver. */
    internal fun mutableSnapshotHash(
        table: PushMutableTable,
        records: List<PushMutableRecord>,
    ): String {
        val lines = records.map { record ->
            validateRecord(table, record.key, record.data)
            encodeRecordLine(record)
        }.sortedWith { left, right -> compareBytes(left, right) }
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update("noop-push-day-hash\n$VERSION\n${table.wireName}\n".toByteArray(Charsets.UTF_8))
        lines.forEach(digest::update)
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    internal fun canonicalJson(value: Any?): String = buildString { appendCanonical(value, sortMaps = true) }

    internal fun canonicalJsonMap(value: Map<String, Any?>): String = buildString {
        appendCanonical(value, sortMaps = true)
    }

    private fun orderedObjectJson(value: Map<String, Any?>): String = buildString {
        appendCanonical(value, sortMaps = false)
    }

    private fun StringBuilder.appendCanonical(value: Any?, sortMaps: Boolean) {
        when (value) {
            null -> append("null")
            is String -> appendQuoted(value)
            is Boolean -> append(if (value) "true" else "false")
            is Byte, is Short, is Int, is Long -> append((value as Number).toLong())
            is Float, is Double -> {
                val d = (value as Number).toDouble()
                if (!d.isFinite()) throw PushProtocolException("non-finite number is not valid JSON")
                append(java.lang.Double.toString(d))
            }
            is Map<*, *> -> {
                val entries = value.entries.map {
                    val key = it.key as? String ?: throw PushProtocolException("JSON object key must be a string")
                    key to it.value
                }.let { if (sortMaps) it.sortedBy { entry -> entry.first } else it }
                append('{')
                entries.forEachIndexed { index, (key, item) ->
                    if (index > 0) append(',')
                    appendQuoted(key)
                    append(':')
                    appendCanonical(item, sortMaps)
                }
                append('}')
            }
            is Iterable<*> -> {
                append('[')
                value.forEachIndexed { index, item ->
                    if (index > 0) append(',')
                    appendCanonical(item, sortMaps)
                }
                append(']')
            }
            else -> throw PushProtocolException("unsupported JSON value ${value::class.java.name}")
        }
    }

    private fun StringBuilder.appendQuoted(value: String) {
        append('"')
        for (ch in value) {
            when (ch) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\b' -> append("\\b")
                '\u000C' -> append("\\f")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (ch.code < 0x20) append("\\u%04x".format(ch.code)) else append(ch)
            }
        }
        append('"')
    }

    private fun encodeRecordLine(record: PushAppendRecord): ByteArray =
        encodeLine(mapOf("data" to record.data, "key" to record.key, "type" to "record"))

    private fun encodeRecordLine(record: PushMutableRecord): ByteArray =
        encodeLine(mapOf("data" to record.data, "key" to record.key, "type" to "record"))

    private fun encodeLine(value: Map<String, Any?>): ByteArray =
        (canonicalJson(value) + "\n").toByteArray(Charsets.UTF_8)

    private fun appendIdentity(
        sourceId: String,
        table: PushAppendTable,
        deviceId: String,
        start: PushCursor?,
        end: PushCursor,
        count: Int,
        protocolVersion: String = VERSION,
    ): Map<String, Any?> = mapOf(
        "delivery" to "append",
        "deviceId" to deviceId,
        "endCursor" to cursorJson(end),
        "protocolVersion" to protocolVersion,
        "recordCount" to count,
        "sourceId" to sourceId,
        "startCursor" to start?.let(::cursorJson),
        "stream" to table.wireName,
        "type" to "batch",
    )

    private fun appendHeader(
        sourceId: String,
        table: PushAppendTable,
        deviceId: String,
        start: PushCursor?,
        end: PushCursor,
        count: Int,
        batchId: String,
        protocolVersion: String = VERSION,
    ): ByteArray = encodeLine(appendIdentity(sourceId, table, deviceId, start, end, count, protocolVersion) + ("batchId" to batchId))

    private fun mutableIdentity(
        sourceId: String,
        table: PushMutableTable,
        deviceId: String,
        window: PushWindow,
        replacementId: String,
        part: Int,
        parts: Int,
        count: Int,
    ): Map<String, Any?> = mapOf(
        "delivery" to "replace_window",
        "deviceId" to deviceId,
        "endCursor" to null,
        "protocolVersion" to VERSION,
        "recordCount" to count,
        "sourceId" to sourceId,
        "startCursor" to null,
        "stream" to table.wireName,
        "type" to "batch",
        "window" to (selectorBounds(table, window) + mapOf(
            "part" to part,
            "parts" to parts,
            "replacementId" to replacementId,
        )),
    )

    private fun mutableHeader(
        sourceId: String,
        table: PushMutableTable,
        deviceId: String,
        window: PushWindow,
        replacementId: String,
        part: Int,
        parts: Int,
        count: Int,
        batchId: String,
    ): ByteArray = encodeLine(
        mutableIdentity(sourceId, table, deviceId, window, replacementId, part, parts, count) +
            ("batchId" to batchId),
    )

    private fun selectorBounds(table: PushMutableTable, window: PushWindow): Map<String, Any?> = when (table) {
        PushMutableTable.DAILY_METRIC, PushMutableTable.JOURNAL -> mapOf(
            "endExclusive" to java.time.LocalDate.parse(window.toDay).plusDays(1).toString(),
            "selector" to "day",
            "startInclusive" to window.fromDay,
        )
        PushMutableTable.SLEEP_SESSION, PushMutableTable.WORKOUT -> mapOf(
            "endExclusive" to window.endTsExclusive,
            "selector" to "startTs",
            "startInclusive" to window.startTsInclusive,
        )
    }

    private fun cursorFor(table: PushAppendTable, deviceId: String, record: PushAppendRecord) =
        PushCursor(record.rowId, keyFingerprint(table, deviceId, record.key))

    private fun cursorJson(cursor: PushCursor): Map<String, Any?> = mapOf(
        "keySha256" to cursor.naturalKeyFingerprint,
        "rowId" to cursor.rowId,
    )

    private fun stableUuid(header: Map<String, Any?>, lines: List<ByteArray>): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(canonicalJson(header).toByteArray(Charsets.UTF_8))
        digest.update('\n'.code.toByte())
        lines.forEach(digest::update)
        val bytes = digest.digest().copyOf(16)
        bytes[6] = ((bytes[6].toInt() and 0x0f) or 0x50).toByte()
        bytes[8] = ((bytes[8].toInt() and 0x3f) or 0x80).toByte()
        val buffer = java.nio.ByteBuffer.wrap(bytes)
        return UUID(buffer.long, buffer.long).toString()
    }

    private fun concatenate(header: ByteArray, lines: List<ByteArray>): ByteArray {
        val out = ByteArray(header.size + lines.sumOf { it.size })
        var offset = 0
        header.copyInto(out, offset)
        offset += header.size
        lines.forEach { line ->
            line.copyInto(out, offset)
            offset += line.size
        }
        return out
    }

    private fun compareBytes(left: ByteArray, right: ByteArray): Int {
        val common = minOf(left.size, right.size)
        for (index in 0 until common) {
            val difference = (left[index].toInt() and 0xff) - (right[index].toInt() and 0xff)
            if (difference != 0) return difference
        }
        return left.size - right.size
    }

    private fun validateRecord(table: PushTable, key: Map<String, Any?>, data: Map<String, Any?>) {
        val spec = REGISTRY.getValue(table.wireName)
        if (key.keys.toList() != spec.first) throw PushProtocolException("${table.wireName} key does not match registry")
        if (data.keys.toSet() != spec.second.toSet() || data.size != spec.second.size) {
            throw PushProtocolException("${table.wireName} data does not match registry")
        }
        if ("deviceId" in key || "deviceId" in data || "synced" in data) {
            throw PushProtocolException("batch-scoped or local-only column in record")
        }
    }

    private fun validateRecordKeys(table: PushAppendTable, key: Map<String, Any?>) {
        if (key.keys.toList() != REGISTRY.getValue(table.wireName).first) {
            throw PushProtocolException("${table.wireName} key does not match registry")
        }
    }

    private fun scalarRecord(table: PushAppendTable, row: PushAppendRecord, version: String): PushAppendRecord? {
        validateRecordKeys(table, row.key)
        fun integer(value: Any?): Long {
            if (value !is Int && value !is Long && value !is Short && value !is Byte)
                throw PushProtocolException("Scalar integer has invalid type")
            return (value as Number).toLong()
        }
        if (integer(row.key["ts"]) <= 0) throw PushProtocolException("Invalid scalar timestamp")
        val columns = REGISTRY.getValue(table.wireName).second
        if (row.data.keys.any { it !in columns && it != "provenance" } || !row.data.keys.contains(columns.first()))
            throw PushProtocolException("Scalar data does not match registry")
        val data = columns.associateTo(linkedMapOf()) { it to row.data[it] }
        when (table) {
            PushAppendTable.STEP_SAMPLE -> {
                if (integer(data["counter"]) !in 0..65535L || data["activityClass"]?.let { integer(it) !in 0..2 } == true)
                    throw PushProtocolException("Invalid step scalar")
            }
            PushAppendTable.SLEEP_STATE_SAMPLE -> {
                val state = integer(data["state"])
                val raw = data["rawByte"]?.let(::integer)
                if (state !in 0..3 || raw?.let { it !in 0..255 || (it shr 4) and 3 != state } == true)
                    throw PushProtocolException("Invalid sleep-state scalar")
            }
            PushAppendTable.PPG_HR_SAMPLE -> {
                val conf = data["conf"]
                if (integer(data["bpm"]) <= 0 || conf != null && (conf !is Number || !conf.toDouble().isFinite() || conf.toDouble() !in 0.0..1.0))
                    throw PushProtocolException("Invalid derived-HR scalar")
            }
            else -> throw PushProtocolException("Not a scalar extension")
        }
        val provenance = row.data["provenance"]
        if (provenance != null && provenance !is Map<*, *>) throw PushProtocolException("Provenance must be an object")
        if (provenance != null && version != "1.4") return null
        if (version == "1.4") data["provenance"] = provenance?.let {
            try { com.noop.data.ScalarProvenance.validated(it as Map<*, *>) }
            catch (_: Exception) { throw PushProtocolException("Invalid scalar provenance") }
        }
        return PushAppendRecord(row.rowId, row.key, data)
    }

    fun schemaVersion(stream: String, version: String): Int = when {
        stream == "ppgWaveformSample" && version in setOf("1.3", "1.4") -> 2
        version == "1.4" && stream in setOf("v18AuxSample", "stepSample", "sleepStateSample", "ppgHrSample") -> 2
        else -> 1
    }

    private fun validateUuid(value: String, name: String) {
        if (runCatching { UUID.fromString(value).toString() }.getOrNull() != value) {
            throw PushProtocolException("$name must be a lowercase canonical UUID")
        }
    }

    private fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256")
        .digest(bytes).joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private const val UUID_PLACEHOLDER = "00000000-0000-0000-0000-000000000000"

    private val REGISTRY: Map<String, Pair<List<String>, List<String>>> = mapOf(
        "hrSample" to (listOf("ts") to listOf("bpm")),
        "rrInterval" to (listOf("ts", "rrMs", "seq") to listOf("ord", "srcChannel", "tsSuspect")),
        "event" to (listOf("ts", "kind") to listOf("payloadJSON")),
        "battery" to (listOf("ts") to listOf("soc", "mv", "charging")),
        "spo2Sample" to (listOf("ts") to listOf("red", "ir")),
        "skinTempSample" to (listOf("ts") to listOf("raw", "aux1Raw", "aux2Raw")),
        "respSample" to (listOf("ts") to listOf("raw")),
        "gravitySample" to (listOf("ts") to listOf("x", "y", "z", "dynAccel")),
        "stepSample" to (listOf("ts") to listOf("counter", "activityClass")),
        "sleepStateSample" to (listOf("ts") to listOf("state", "rawByte")),
        "ppgHrSample" to (listOf("ts") to listOf("bpm", "conf")),
        "dailyMetric" to (listOf("day") to listOf(
            "totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances",
            "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct",
            "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir",
        )),
        "sleepSession" to (listOf("startTs") to listOf(
            "endTs", "efficiency", "restingHr", "avgHrv", "stagesJSON", "userEdited",
            "startTsAdjusted", "motionJSON", "sleepStateJSON", "stagingSparse",
        )),
        "workout" to (listOf("startTs", "sport") to listOf(
            "endTs", "source", "durationS", "energyKcal", "avgHr", "maxHr", "strain",
            "distanceM", "zonesJSON", "notes", "routePolyline", "steps",
        )),
        "journal" to (listOf("day", "question") to listOf("answeredYes", "notes", "numericValue")),
    )
}

data class PushAck(
    val protocolVersion: String,
    val batchId: String,
    val stream: String,
    val deviceId: String,
    val endCursor: PushCursor?,
    val acceptedRows: Int,
    val status: String,
) {
    fun encode(): ByteArray = PushProtocol.canonicalJson(
        mapOf(
            "acceptedRows" to acceptedRows,
            "batchId" to batchId,
            "deviceId" to deviceId,
            "endCursor" to endCursor?.let {
                mapOf("keySha256" to it.naturalKeyFingerprint, "rowId" to it.rowId)
            },
            "protocolVersion" to protocolVersion,
            "status" to status,
            "stream" to stream,
        ),
    ).toByteArray(Charsets.UTF_8)

    fun exactlyMatches(batch: PushBatch): Boolean =
        protocolVersion == batch.protocolVersion && batchId == batch.batchId &&
            stream == batch.table.wireName && deviceId == batch.deviceId &&
            endCursor == batch.endCursor && acceptedRows == batch.recordCount && status == "accepted"

    fun exactlyMatches(batch: PushBinaryBatch): Boolean =
        protocolVersion == batch.protocolVersion && batchId == batch.batchId &&
            stream == batch.wireName && deviceId == batch.deviceId &&
            endCursor == batch.endCursor && acceptedRows == batch.sampleCount && status == "accepted"

    companion object {
        fun fromBatch(batch: PushBatch): PushAck = PushAck(
            batch.protocolVersion, batch.batchId, batch.table.wireName, batch.deviceId,
            batch.endCursor, batch.recordCount, "accepted",
        )

        fun parse(bytes: ByteArray): PushAck {
            if (bytes.size > PushProtocol.MAX_ACK_BYTES) throw PushProtocolException("ack exceeds size limit")
            val obj = try {
                JSONObject(bytes.toString(Charsets.UTF_8))
            } catch (_: Throwable) {
                throw PushProtocolException("ack is not valid JSON")
            }
            val expectedMembers = setOf(
                "protocolVersion", "batchId", "stream", "deviceId", "endCursor",
                "acceptedRows", "status",
            )
            val actualMembers = obj.keys().asSequence().toSet()
            if (!actualMembers.containsAll(expectedMembers)) {
                throw PushProtocolException("ack is missing required protocol 1.0 members")
            }
            if (actualMembers.any { it in PushProtocol.FORBIDDEN_REMOTE_CONTROL_MEMBERS }) {
                throw PushProtocolException("ack contains forbidden remote-control metadata")
            }
            fun string(name: String): String = (obj.opt(name) as? String)?.takeIf { it.isNotEmpty() }
                ?: throw PushProtocolException("ack.$name must be a non-empty string")
            fun integer(value: Any?, name: String): Long {
                // JSONObject retains integer tokens as Int/Long. Never coerce floating point:
                // Double(2^63).toLong() saturates and round-trips through Double as Long.MAX_VALUE.
                if (value !is Int && value !is Long) throw PushProtocolException("ack.$name must be an integer")
                return (value as Number).toLong()
            }
            val cursor = when (val raw = obj.opt("endCursor")) {
                null, JSONObject.NULL -> null
                is JSONObject -> {
                    if (!raw.keys().asSequence().toSet().containsAll(setOf("rowId", "keySha256"))) {
                        throw PushProtocolException("ack.endCursor is missing required protocol 1.0 members")
                    }
                    val rowId = integer(raw.opt("rowId"), "endCursor.rowId")
                    if (rowId < 0) throw PushProtocolException("ack.endCursor.rowId must be nonnegative")
                    val sha = (raw.opt("keySha256") as? String)?.takeIf { it.matches(Regex("[0-9a-f]{64}")) }
                        ?: throw PushProtocolException("ack.endCursor.keySha256 must be lowercase SHA-256")
                    PushCursor(rowId, sha)
                }
                else -> throw PushProtocolException("ack.endCursor must be an object or null")
            }
            val acceptedRows = integer(obj.opt("acceptedRows"), "acceptedRows")
            if (acceptedRows !in 0..PushProtocol.MAX_RECORDS.toLong())
                throw PushProtocolException("ack.acceptedRows exceeds the batch bound")
            return PushAck(
                protocolVersion = string("protocolVersion"),
                batchId = string("batchId"),
                stream = string("stream"),
                deviceId = string("deviceId"),
                endCursor = cursor,
                acceptedRows = acceptedRows.toInt(),
                status = string("status"),
            )
        }
    }
}
