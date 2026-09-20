package com.noop.protocol

import org.junit.Assert.*
import org.junit.Test

class StandardHrReceiptTest {
    private val session = "11111111-2222-3333-4444-555555555555"
    @Test fun originalWordsRetainEqualAndInvalidSlotsWithoutBeatClockClaims() {
        val p = StandardHrReceipt.capture(byteArrayOf(0x16, 60, 0, 4, 0, 0, 0, 4), session, 7,
            1700000000999, 10000000000000001)!!
        assertEquals(listOf(1024, 0, 1024), p.rrRawTicks)
        assertEquals(1700000000, p.ts)
        assertEquals("host-arrival-unmapped", p.clockVersion)
        assertTrue(p.isValid)
        assertFalse(p.copy(ts = p.ts + 1).isValid)
        assertFalse(p.copy(receiptId = "wrong").isValid)
    }
    @Test fun sameSecondIdenticalNotificationsRemainDistinctAndReplayIsStable() {
        fun capture(ordinal: Long) = StandardHrReceipt.capture(byteArrayOf(0x10, 60, 0, 4), session, ordinal, 1001, 2000)!!
        assertNotEquals(capture(0).receiptId, capture(1).receiptId)
        assertEquals(capture(0), capture(0))
        assertNull(StandardHrReceipt.capture(byteArrayOf(0), "invalid", 0, 0, 0))
    }
    @Test fun truncatedPayloadRetainsEvidenceWithoutPartialTrain() {
        for (bytes in listOf(byteArrayOf(0x10,60,0), byteArrayOf(0x18,60,0), byteArrayOf(0x10,60), byteArrayOf(1,60))) {
            val receipt = StandardHrReceipt.capture(bytes, session, 0, 0, 0)!!
            assertTrue(receipt.isValid)
            assertNull(receipt.rrRawTicks)
        }
    }
}
