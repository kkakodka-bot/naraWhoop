package com.noop.push

import org.junit.Assert.*
import org.junit.Test

class PushDiagnosticTest {
    private val request = "ABCDEF01-2222-3333-4444-555555555555"

    @Test fun exactInlineAndObjectVersionsKeepDiagnosticsAndLocalAttribution() {
        for (version in listOf("1.0", "1.1", "1.2")) {
            val body = """{"type":"error","protocolVersion":"$version","code":"push_failed","stage":"projection","correlationId":"$request"}""".toByteArray()
            val failure = PushError.httpFailure(500, body, expectedVersion = version,
                table = if (version == "1.2") null else PushAppendTable.HR_SAMPLE)
            assertEquals("projection", failure.stage)
            assertEquals(request.lowercase(), failure.correlationId)
            if (version == "1.0") assertEquals("hrSample", failure.stream)
            if (version == "1.2") {
                assertNull(failure.stream)
                assertEquals("rawBatch", failure.attributedTo(PushBinaryTable.RAW_BATCH).stream)
            }
            assertNull(PushError.httpFailure(500, body,
                expectedVersion = if (version == "1.0") "1.1" else "1.0").stage)
        }
    }

    @Test fun onlySafeStageAndRequestSurviveAndTheLocalStreamWins() {
        val body = """{"type":"error","protocolVersion":"1.0","code":"receiver_failed","stream":"spo2Sample","stage":"projection","correlationId":"$request","message":"private-health-canary","userId":"owner-canary"}""".toByteArray()
        val failure = PushError.httpFailure(500, body, table = PushAppendTable.RR_PACKET_PROVENANCE)
        assertEquals("rrPacketProvenance", failure.stream)
        assertEquals("projection", failure.stage)
        assertEquals(request.lowercase(), failure.correlationId)
        val message = failure.messageWithDiagnostics("x".repeat(290))
        assertTrue(message.length <= 300)
        assertTrue(message.contains("request=${request.lowercase()}"))
        assertFalse(message.contains("canary"))
        assertFalse(message.contains("spo2Sample"))
    }

    @Test fun UnknownFieldsAndMalformedEnvelopesCannotBecomeDiagnostics() {
        val body = """{"type":"error","protocolVersion":"1.0","code":"receiver_failed","stage":"private-health-canary","correlationId":"owner-canary"}""".toByteArray()
        val failure = PushError.httpFailure(500, body, table = PushAppendTable.HR_SAMPLE)
        assertNull(failure.stage)
        assertNull(failure.correlationId)
        assertEquals("stream=hrSample", failure.safeDiagnosticSummary)
        val mismatched = PushError.httpFailure(500, body, expectedVersion = "3.0", table = PushAppendTable.HR_SAMPLE)
        assertNull(mismatched.receiverCode)
        assertEquals("stream=hrSample", mismatched.safeDiagnosticSummary)
        assertNull(PushError.httpFailure(500, ByteArray(PushProtocol.MAX_ACK_BYTES + 1)).safeDiagnosticSummary)
    }

    @Test fun OlderReceiverErrorsRemainCompatible() {
        val body = """{"type":"error","protocolVersion":"1.0","code":"receiver_failed"}""".toByteArray()
        val failure = PushError.httpFailure(500, body)
        assertEquals("receiver_failed", failure.receiverCode)
        assertNull(failure.safeDiagnosticSummary)
        assertEquals("HTTP 500 (receiver_failed)", failure.messageWithDiagnostics("HTTP 500"))
    }
}
