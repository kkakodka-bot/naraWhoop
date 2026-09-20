package com.noop.push

import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.time.format.ResolverStyle

/** Parsed receipt data only. Matching is not authentication, journal settlement or cleanup authority. */
class PushDurabilityReceipt private constructor(
    val version: Int,
    val state: String,
    val receiptId: String,
    val ownerUserId: String,
    val deviceId: String,
    val objectId: String,
    val batchId: String,
    val sourceId: String,
    val stream: String,
    val schemaVersion: Int,
    val objectKey: String,
    val contentSha256: String,
    val wireSha256: String,
    val compressedBytes: Long,
    val uncompressedBytes: Long,
    val verifiedAt: String,
    val indexedAt: String,
) {
    /** Caller freezes this from the request, including the canonical server device UUID. */
    data class ExpectedContent(
        val ownerUserId: String,
        val deviceId: String,
        val objectId: String,
        val batchId: String,
        val sourceId: String,
        val stream: String,
        val schemaVersion: Int,
        val contentSha256: String,
        val uncompressedBytes: Long,
    ) {
        init {
            require(listOf(ownerUserId, deviceId, objectId, batchId, sourceId).all(::canonicalUuid) &&
                validStream(stream) && schemaVersion > 0 && digest(contentSha256) && uncompressedBytes > 0) {
                "Invalid receipt expectation"
            }
        }
    }

    data class ExpectedObject(
        val content: ExpectedContent,
        val wireSha256: String,
        val compressedBytes: Long,
        // Null is explicit when a duplicate receipt arrives before an upload intent is known.
        val stagingObjectKey: String?,
        val verifiedObjectKey: String? = null,
    ) {
        init {
            require(digest(wireSha256) && compressedBytes > 0 &&
                (stagingObjectKey == null || validKey(stagingObjectKey)) &&
                (verifiedObjectKey == null || validKey(verifiedObjectKey)) &&
                (stagingObjectKey == null || stagingObjectKey != verifiedObjectKey)) {
                "Invalid receipt expectation"
            }
        }
    }

    /** Edge recompresses inline NDJSON. Client gzip hash/size are deliberately not inputs here. */
    data class ExpectedInline(val content: ExpectedContent, val verifiedObjectKey: String? = null) {
        init {
            require(content.objectId == content.batchId && (verifiedObjectKey == null || validKey(verifiedObjectKey))) {
                "Invalid receipt expectation"
            }
        }
    }

    fun matches(expected: ExpectedObject): Boolean = matchesContent(expected.content) &&
        wireSha256 == expected.wireSha256 && compressedBytes == expected.compressedBytes &&
        objectKey != expected.stagingObjectKey &&
        (expected.verifiedObjectKey == null || objectKey == expected.verifiedObjectKey)

    fun matches(expected: ExpectedInline): Boolean = matchesContent(expected.content) &&
        (expected.verifiedObjectKey == null || objectKey == expected.verifiedObjectKey)

    private fun matchesContent(expected: ExpectedContent): Boolean = ownerUserId == expected.ownerUserId &&
        deviceId == expected.deviceId && objectId == expected.objectId && batchId == expected.batchId &&
        sourceId == expected.sourceId && stream == expected.stream && schemaVersion == expected.schemaVersion &&
        contentSha256 == expected.contentSha256 && uncompressedBytes == expected.uncompressedBytes

    companion object {
        const val MAX_BYTES = 64 * 1024
        private val uuidPattern = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
        private val digestPattern = Regex("[0-9a-f]{64}")
        private val timestampPattern = Regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})")
        private val integerFields = setOf("version", "schemaVersion", "compressedBytes", "uncompressedBytes")
        private val stringFields = setOf("state", "receiptId", "ownerUserId", "deviceId", "objectId", "batchId",
            "sourceId", "stream", "objectKey", "contentSha256", "wireSha256", "verifiedAt", "indexedAt")
        private fun canonicalUuid(value: String) = uuidPattern.matches(value)
        private fun digest(value: String) = digestPattern.matches(value)
        private fun validStream(value: String) = value.isNotEmpty() && value.length <= 128 &&
            value.none { it.isWhitespace() || it.isISOControl() }
        private fun validKey(value: String) = value.isNotEmpty() && value.length <= 1024 &&
            value.none { it.isWhitespace() || it.isISOControl() }
        private fun timestamp(value: String): Instant {
            if (!timestampPattern.matches(value)) invalid()
            return try {
                OffsetDateTime.parse(value, DateTimeFormatter.ISO_OFFSET_DATE_TIME.withResolverStyle(ResolverStyle.STRICT)).toInstant()
            } catch (_: java.time.DateTimeException) { invalid() }
        }
        private fun invalid(): Nothing = throw InvalidReceiptException()

        /** Exact flat v1 object, not an ACK wrapper. Unknown/duplicate members fail closed. */
        fun parse(bytes: ByteArray): PushDurabilityReceipt {
            if (bytes.isEmpty() || bytes.size > MAX_BYTES) invalid()
            val text = try {
                Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
            } catch (_: java.nio.charset.CharacterCodingException) { invalid() }
            val fields = ReceiptJson(text).read()
            fun string(name: String) = fields[name] as? String ?: invalid()
            fun integer(name: String) = fields[name] as? Long ?: invalid()
            fun uuid(name: String) = string(name).also { if (!canonicalUuid(it)) invalid() }
            val version = integer("version")
            val schema = integer("schemaVersion")
            if (version != 1L || string("state") != "verified_indexed" || schema !in 1..Int.MAX_VALUE.toLong()) invalid()
            val verified = string("verifiedAt")
            val indexed = string("indexedAt")
            val verifiedInstant = timestamp(verified)
            if (verifiedInstant <= Instant.EPOCH || timestamp(indexed) < verifiedInstant) invalid()
            return PushDurabilityReceipt(1, "verified_indexed", uuid("receiptId"), uuid("ownerUserId"), uuid("deviceId"),
                uuid("objectId"), uuid("batchId"), uuid("sourceId"), string("stream").also { if (!validStream(it)) invalid() },
                schema.toInt(), string("objectKey").also { if (!validKey(it)) invalid() },
                string("contentSha256").also { if (!digest(it)) invalid() },
                string("wireSha256").also { if (!digest(it)) invalid() },
                integer("compressedBytes"), integer("uncompressedBytes"), verified, indexed)
        }

        // A flat schema reader preserves integer token types on both Android and host JVM.
        // JSONObject's platform-specific coercion and duplicate-key handling cannot do that.
        private class ReceiptJson(private val text: String) {
            private var position = 0
            private fun peek(): Char? = text.getOrNull(position)
            private fun whitespace() { while (peek() in listOf(' ', '\t', '\r', '\n')) position++ }
            private fun take(value: Char) { whitespace(); if (peek() != value) invalid(); position++ }
            fun read(): Map<String, Any> {
                val fields = linkedMapOf<String, Any>()
                take('{')
                while (true) {
                    whitespace()
                    val name = string()
                    if (fields.containsKey(name) || name !in stringFields && name !in integerFields) invalid()
                    take(':'); whitespace()
                    fields[name] = if (name in stringFields) string() else positiveInteger()
                    whitespace()
                    if (peek() == '}') { position++; break }
                    take(',')
                }
                whitespace()
                if (position != text.length || fields.keys != stringFields + integerFields) invalid()
                return fields
            }
            private fun positiveInteger(): Long {
                val start = position
                if (peek() !in '1'..'9') invalid()
                while (peek() in '0'..'9') position++
                return text.substring(start, position).toLongOrNull() ?: invalid()
            }
            private fun string(): String {
                take('"')
                val result = StringBuilder()
                while (true) {
                    val value = peek() ?: invalid(); position++
                    if (value == '"') break
                    if (value < ' ') invalid()
                    if (value != '\\') { result.append(value); continue }
                    val escaped = peek() ?: invalid(); position++
                    result.append(when (escaped) {
                        '"', '\\', '/' -> escaped
                        'b' -> '\b'; 'f' -> '\u000c'; 'n' -> '\n'; 'r' -> '\r'; 't' -> '\t'
                        'u' -> {
                            if (position + 4 > text.length) invalid()
                            val hex = text.substring(position, position + 4)
                            if (!hex.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) invalid()
                            position += 4; hex.toInt(16).toChar()
                        }
                        else -> invalid()
                    })
                }
                var index = 0
                while (index < result.length) {
                    val value = result[index++]
                    if (Character.isHighSurrogate(value)) {
                        if (index == result.length || !Character.isLowSurrogate(result[index++])) invalid()
                    } else if (Character.isLowSurrogate(value)) invalid()
                }
                return result.toString()
            }
        }
    }

    class InvalidReceiptException internal constructor() : IllegalArgumentException("Invalid durability receipt")
}
