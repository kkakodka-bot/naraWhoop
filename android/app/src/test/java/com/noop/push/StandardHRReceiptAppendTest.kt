package com.noop.push

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class StandardHRReceiptAppendTest {
    @Test fun sameSecondEqualNotificationsKeepIdentityAndNanosecondsAcrossJson() {
        val session = "00000000-0000-4000-8000-000000000001"
        val rows = (0..1).map { ordinal -> PushAppendRecord((ordinal + 1).toLong(),
            mapOf("receiptId" to "$session:$ordinal"), mapOf(
                "ts" to 1700000000L, "sessionId" to session, "notificationOrdinal" to ordinal,
                "receivedUnixMs" to 1700000000123L, "receivedMonotonicNs" to "9007199254740993",
                "rawHex" to "103c0004", "schemaVersion" to 1, "clockVersion" to "host-arrival-unmapped")) }
        val source = "00000000-0000-4000-8000-000000000002"
        val batch = PushProtocol.appendBatch(PushAppendTable.STANDARD_HR_RECEIPT, source, "d", null, rows)
        val replay = PushProtocol.appendBatch(PushAppendTable.STANDARD_HR_RECEIPT, source, "d", null, rows)
        assertEquals("1.1", batch.protocolVersion)
        assertEquals(2, batch.recordCount)
        assertArrayEquals(batch.body, replay.body)
        val lines = batch.body.toString(Charsets.UTF_8).trimEnd().lines().map(::JSONObject)
        assertEquals("1.1", lines[0].getString("protocolVersion"))
        for (ordinal in 0..1) {
            val row = lines[ordinal + 1]
            assertEquals("$session:$ordinal", row.getJSONObject("key").getString("receiptId"))
            assertEquals("9007199254740993", row.getJSONObject("data").getString("receivedMonotonicNs"))
            assertFalse(row.getJSONObject("data").has("verifiedSpan"))
        }
    }
}
