package com.noop.push

import org.json.JSONObject
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

/** Exact request bytes survive source retention, new arrivals and process death. Stored only in
 * the existing encrypted owner/endpoint progress store; this lane never authorizes local pruning. */
internal object PushFreshSelection {
    const val MAX_BYTES = 64 * 1024
    const val MAX_RECORDS = 128
    const val WINDOW_SECONDS = 300L
    private const val MAX_ENCODED_BYTES = 90 * 1024

    fun encode(batch: PushBatch): String {
        require(batch.mode == "append" && batch.body.size <= MAX_BYTES)
        val result = JSONObject().put("v", 1).put("sha256", digest(batch.body))
            .put("body", Base64.getEncoder().encodeToString(batch.body)).toString()
        val restored = decode(result)
        require(restored.batchId == batch.batchId && restored.startCursor == batch.startCursor &&
            restored.endCursor == batch.endCursor && restored.recordCount == batch.recordCount &&
            restored.sourceId == batch.sourceId && restored.deviceId == batch.deviceId && restored.table == batch.table)
        return result
    }

    fun decode(encoded: String): PushBatch {
        require(encoded.length <= MAX_ENCODED_BYTES)
        val envelope = JSONObject(encoded)
        require(envelope.keys().asSequence().toSet() == setOf("v", "sha256", "body") && envelope.get("v") == 1)
        val body = Base64.getDecoder().decode(envelope.getString("body"))
        require(body.size in 1..MAX_BYTES && digest(body) == envelope.getString("sha256"))
        val lines = body.toString(Charsets.UTF_8).split('\n')
        require(lines.last().isEmpty())
        val header = JSONObject(lines.first())
        require(header.keys().asSequence().toSet() == setOf("delivery", "deviceId", "endCursor", "protocolVersion",
            "recordCount", "sourceId", "startCursor", "stream", "type", "batchId"))
        require(header.getString("delivery") == "append" && header.getString("type") == "batch")
        val countValue = integer(header, "recordCount")
        require(countValue in 1..MAX_RECORDS.toLong())
        val count = countValue.toInt()
        require(count in 1..MAX_RECORDS && lines.size == count + 2)
        val table = PushAppendTable.entries.single { it.wireName == header.getString("stream") }
        val source = header.getString("sourceId")
        val batchId = header.getString("batchId")
        require(UUID.fromString(source).toString() == source && UUID.fromString(batchId).toString() == batchId)
        val start = if (header.isNull("startCursor")) null else cursor(header.getJSONObject("startCursor"))
        val end = cursor(header.getJSONObject("endCursor"))
        require(end.rowId > (start?.rowId ?: 0))
        val version = header.getString("protocolVersion")
        require(version in setOf("1.0", "1.1", "1.2", "1.3", "1.4"))
        val batch = PushBatch(version, batchId, source, table, header.getString("deviceId"), "append",
            start, end, count, null, body = body)
        require(PushProtocol.hasFreshIdentity(batch))
        return batch
    }

    private fun integer(value: JSONObject, key: String): Long {
        val number = value.get(key)
        require(number is Int || number is Long)
        return (number as Number).toLong()
    }

    private fun cursor(value: JSONObject): PushCursor {
        require(value.keys().asSequence().toSet() == setOf("rowId", "keySha256"))
        val row = integer(value, "rowId")
        val hash = value.getString("keySha256")
        require(row > 0 && hash.matches(Regex("[0-9a-f]{64}")))
        return PushCursor(row, hash)
    }

    private fun digest(value: ByteArray) = MessageDigest.getInstance("SHA-256").digest(value)
        .joinToString("") { "%02x".format(it.toInt() and 255) }
}
