package com.noop.protocol

/** Immutable checked WHOOP5 v18 sensor record. V1 contains no reconstructed beat clock. */
data class RrPacketProvenance(
    val packetId: String, val ts: Long, val sensorTs: Long, val recordIndex: Long, val rawHex: String,
    val srcChannel: Int, val schemaVersion: Int, val decoderVersion: String, val clockVersion: String,
    val timestampPrecisionSeconds: Double, val clockOffsetSeconds: Long, val declaredCount: Int,
) {
    data class Word(val index: Int, val rawTicks: Int) {
        val rrMs: Int get() = Whoop5RR.milliseconds(rawTicks)
    }
    fun words(): List<Word> {
        if (declaredCount !in 1..4) return emptyList()
        val frame = bytes(rawHex) ?: return emptyList()
        if (checked(frame, ts) != this || 24 + declaredCount * 2 > u16(frame, 2) + 4) return emptyList()
        return (0 until declaredCount).map { Word(it, u16(frame, 24 + it * 2)) }
    }
    companion object {
        private fun u16(frame: ByteArray, off: Int) = (frame[off].toInt() and 255) or ((frame[off + 1].toInt() and 255) shl 8)
        private fun u32(frame: ByteArray, off: Int) = (0..3).fold(0L) { value, i -> value or ((frame[off + i].toLong() and 255) shl (i * 8)) }
        private fun hex(bytes: ByteArray): String {
            val alphabet = "0123456789abcdef"
            return CharArray(bytes.size * 2) { i ->
                val byte = bytes[i / 2].toInt() and 255
                alphabet[if (i % 2 == 0) byte ushr 4 else byte and 15]
            }.concatToString()
        }
        fun bytes(hex: String): ByteArray? {
            if (hex.length % 2 != 0 || hex.length > 131086 || hex.any { it !in '0'..'9' && it !in 'a'..'f' }) return null
            return ByteArray(hex.length / 2) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        }
        fun checked(frame: ByteArray, mappedTs: Long? = null): RrPacketProvenance? {
            if (frame.size < 28 || frame[0] != 0xAA.toByte() || frame[8].toInt() != 47 || frame[9].toInt() != 18) return null
            val end = u16(frame, 2) + 4
            if (end + 4 != frame.size || end < 24 || Crc.crc16Modbus(frame, 0, 6) != u16(frame, 6) || Crc.crc32(frame, 8, end) != u32(frame, end)) return null
            val sensorTs = u32(frame, 15); val ts = mappedTs ?: sensorTs
            val id = hex(java.security.MessageDigest.getInstance("SHA-256").digest(frame.copyOfRange(8, end)))
            return RrPacketProvenance(id, ts, sensorTs, u32(frame, 11), hex(frame),
                5, 1, "whoop5-v18-original-words-v1", if (ts == sensorTs) "sensor-second-unmapped" else "legacy-stale-clock-snap300-v1",
                if (ts == sensorTs) 1.0 else 300.0, ts - sensorTs, frame[23].toInt() and 255)
        }
    }
}
