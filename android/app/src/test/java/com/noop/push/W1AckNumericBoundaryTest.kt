package com.noop.push

import org.junit.Assert.*
import org.junit.Test

class W1AckNumericBoundaryTest {
    private fun ack(row: String = "1", count: String = "1") = """{"protocolVersion":"1.4",
        "batchId":"00000000-0000-4000-8000-000000000001","stream":"stepSample","deviceId":"fixture",
        "endCursor":{"rowId":$row,"keySha256":"${"a".repeat(64)}"},"acceptedRows":$count,"status":"accepted"}""".toByteArray()

    @Test fun cursorRequiresExactNonnegativeInt64TokenWithoutOverflowSaturation() {
        for (bad in listOf("true", "false", "\"1\"", "null", "-1", "1.5", "1.0", "1e0", "9223372036854775808",
            "-9223372036854775809", "9.223372036854776E18", "1e100", "{}", "[]"))
            assertTrue("accepted row $bad", runCatching { PushAck.parse(ack(row = bad)) }.exceptionOrNull() is PushProtocolException)
        assertEquals(0L, PushAck.parse(ack(row = "0")).endCursor!!.rowId)
        assertEquals(Long.MAX_VALUE, PushAck.parse(ack(row = Long.MAX_VALUE.toString())).endCursor!!.rowId)
    }

    @Test fun acceptedCountRequiresExactIntegerWithinBatchBound() {
        for (bad in listOf("true", "false", "\"1\"", "null", "-1", "1.5", "1.0", "1e0", "5001", "2147483648",
            "9223372036854775808", "1e100", "{}", "[]"))
            assertTrue("accepted count $bad", runCatching { PushAck.parse(ack(count = bad)) }.exceptionOrNull() is PushProtocolException)
        assertEquals(0, PushAck.parse(ack(count = "0")).acceptedRows)
        assertEquals(PushProtocol.MAX_RECORDS, PushAck.parse(ack(count = PushProtocol.MAX_RECORDS.toString())).acceptedRows)
    }
}
