package com.noop.protocol

import java.util.UUID

/** Original 0x2A37 bytes plus host ARRIVAL clocks, never a verified beat timestamp or continuity claim. */
data class StandardHrReceipt(
    val receiptId: String, val ts: Long, val sessionId: String, val notificationOrdinal: Long,
    val receivedUnixMs: Long, val receivedMonotonicNs: Long, val rawHex: String,
    val schemaVersion: Int = 1, val clockVersion: String = "host-arrival-unmapped",
) {
    val isValid: Boolean get() = RrPacketProvenance.bytes(rawHex)?.let {
        capture(it, sessionId, notificationOrdinal, receivedUnixMs, receivedMonotonicNs) == this
    } == true

    /** Preserve zeros/invalid physiological values and original slot order; reject incomplete fields. */
    val rrRawTicks: List<Int>? get() {
        if (!isValid) return null
        val bytes = RrPacketProvenance.bytes(rawHex) ?: return null
        val flags = bytes[0].toInt() and 255
        var offset = if (flags and 1 == 0) 2 else 3
        if (bytes.size < offset) return null
        if (flags and 8 != 0) offset += 2
        if (bytes.size < offset) return null
        if (flags and 16 == 0) return if (bytes.size == offset) emptyList() else null
        if (bytes.size <= offset || (bytes.size - offset) % 2 != 0) return null
        return (offset until bytes.size step 2).map { (bytes[it].toInt() and 255) or ((bytes[it + 1].toInt() and 255) shl 8) }
    }

    companion object {
        fun capture(bytes: ByteArray, sessionId: String, notificationOrdinal: Long,
                    receivedUnixMs: Long, receivedMonotonicNs: Long): StandardHrReceipt? {
            val id = runCatching { UUID.fromString(sessionId).toString() }.getOrNull() ?: return null
            if (!id.equals(sessionId, ignoreCase = true) || notificationOrdinal < 0 || receivedUnixMs < 0 ||
                receivedMonotonicNs < 0 || bytes.size !in 1..512) return null
            val hex = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
            return StandardHrReceipt("$id:$notificationOrdinal", receivedUnixMs / 1000, id,
                notificationOrdinal, receivedUnixMs, receivedMonotonicNs, hex)
        }
    }
}
