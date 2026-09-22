package com.noop.data

/** Strict identity admission is separate from the tolerant, kernel-shared historical decoder. */
object V18AuxIdentity {
    data class Complete(val recordIndex: Long?)

    fun complete(bytes: ByteArray): Complete? {
        if (bytes.size < V18AuxCodec.HEADER_BYTES || bytes[0].toInt() != V18AuxCodec.FORMAT_VERSION) return null
        var bitmap = 0L
        for (i in 0..3) bitmap = bitmap or ((bytes[i + 1].toLong() and 255) shl (8 * i))
        val known = V18AuxSlot.entries.fold(0L) { bits, slot -> bits or (1L shl slot.index) }
        if (bitmap and known.inv() != 0L) return null
        val expected = V18AuxCodec.HEADER_BYTES + V18AuxSlot.entries.sumOf { if (bitmap and (1L shl it.index) != 0L) it.width else 0 }
        if (bytes.size != expected) return null
        if (bitmap and 1L == 0L) return Complete(null)
        var index = 0L
        for (i in 0..3) index = index or ((bytes[V18AuxCodec.HEADER_BYTES + i].toLong() and 255) shl (8 * i))
        return Complete(index)
    }

    fun pack(row: V18AuxRow): ByteArray {
        V18AuxSlot.entries.forEach { slot ->
            row.slotValues[slot.index]?.let { require(it in 0 until (1L shl (slot.width * 8))) }
        }
        return V18AuxCodec.pack(row)
    }
}
