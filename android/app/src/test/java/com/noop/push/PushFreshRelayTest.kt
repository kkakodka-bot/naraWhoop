package com.noop.push

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class PushFreshRelayTest {
    @Test fun recentSampleIsAttemptedInFirstRunWithoutSkippingHistory() = runBlocking {
        val now = Instant.now().epochSecond
        val rows = (1L..5_000L).map { sample(it, now - 10_000 + it) }.toMutableList()
        rows += sample(10_000, now - 1)
        val source = FakePushSource(append = mutableMapOf("hrSample|wearable" to rows))
        val progress = MemoryProgress()
        val transport = AckingTransport()
        PushCoordinator(source, transport, progress, SOURCE, { LocalDate.of(2026, 9, 22) }, ZoneId.of("UTC"))
            .pushKnownDevices(capabilities = PushCapabilities(setOf(PushAppendTable.HR_SAMPLE), emptySet()))
        assertTrue("Current HR must not wait for 5,000 historical rows", transport.batches.any { it.endCursor?.rowId == 10_000L })
        assertTrue("Fresh delivery cannot skip historical debt", progress.cursor(PushAppendTable.HR_SAMPLE, "wearable")!!.rowId < 10_000)
    }

    @Test fun lostResponseAndSourceCleanupReplayExactFrozenBytesAfterRestart() = runBlocking {
        var now = 20_000L
        val source = FakePushSource(append = mutableMapOf("hrSample|wearable" to mutableListOf(sample(1, now))))
        val progress = MemoryProgress()
        val sent = mutableListOf<ByteArray>()
        var fail = true
        val transport = object : PushTransport {
            override suspend fun post(batch: PushBatch): PushTransportResponse {
                sent += batch.body.copyOf()
                if (fail) throw java.io.IOException("lost response")
                return PushTransportResponse(200, PushAck.fromBatch(batch).encode())
            }
        }
        fun coordinator() = PushCoordinator(source, transport, progress, SOURCE,
            { LocalDate.of(2026, 9, 22) }, ZoneId.of("UTC"), nowSeconds = { now })
        assertTrue(coordinator().pushFreshAppend(PushAppendTable.HR_SAMPLE, "wearable") is PushResult.Rejected)
        assertNull(progress.freshCursor(PushAppendTable.HR_SAMPLE, "wearable"))
        source.append.getValue("hrSample|wearable").clear() // independent history retention
        now += 10_000
        source.append.getValue("hrSample|wearable") += sample(2, now)
        fail = false
        assertTrue(coordinator().pushFreshAppend(PushAppendTable.HR_SAMPLE, "wearable") is PushResult.Accepted)
        assertArrayEquals(sent[0], sent[1])
        assertEquals(1L, progress.freshCursor(PushAppendTable.HR_SAMPLE, "wearable")!!.rowId)
        assertNull(progress.cursor(PushAppendTable.HR_SAMPLE, "wearable"))
        assertTrue(coordinator().pushFreshAppend(PushAppendTable.HR_SAMPLE, "wearable") is PushResult.Accepted)
        assertEquals(2L, progress.freshCursor(PushAppendTable.HR_SAMPLE, "wearable")!!.rowId)
    }

    @Test fun sameRowsHaveDistinctHistoryAndFreshIdentitiesAndStableFreshRetry() {
        val rows = listOf(sample(1, 100))
        val history = PushProtocol.appendBatch(PushAppendTable.HR_SAMPLE, SOURCE, "wearable", null, rows)
        val fresh = PushProtocol.appendBatch(PushAppendTable.HR_SAMPLE, SOURCE, "wearable", null, rows, fresh = true)
        assertNotEquals(history.batchId, fresh.batchId)
        assertEquals("c4afd85c-4827-56a8-b6bb-cfb6168339ef", history.batchId)
        assertEquals("884f3108-6768-54c4-9f1b-82236a5e842b", fresh.batchId)
        fun digest(bytes: ByteArray) = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        assertEquals("3301fbc9c97a5e80d53eb50b9158980e9799a52323f0d6f130558643390f7a8f", digest(history.body))
        assertEquals("d0ecbd8c3caece9fd34d90d662795e0a199e43f3d652628fc63ca8ca7fa1a6a7", digest(fresh.body))
        assertArrayEquals(fresh.body, PushFreshSelection.decode(PushFreshSelection.encode(fresh)).body)
        assertEquals(history.endCursor, fresh.endCursor)
        assertEquals("append", fresh.mode)
        try { PushFreshSelection.encode(history); fail("Ordinary identity cannot advance fresh progress") }
        catch (_: IllegalArgumentException) { }
    }

    @Test fun crashAfterFreshCursorCommitOnlyCleansExactAcknowledgedSelection() = runBlocking {
        val batch = PushProtocol.appendBatch(PushAppendTable.HR_SAMPLE, SOURCE, "wearable", null,
            listOf(sample(1, 100)), fresh = true)
        val progress = MemoryProgress()
        progress.savePendingFreshBatch(PushAppendTable.HR_SAMPLE, "wearable", batch)
        progress.saveFreshCursor(PushAppendTable.HR_SAMPLE, "wearable", batch.endCursor!!)
        val transport = AckingTransport()
        val result = PushCoordinator(FakePushSource(), transport, progress, SOURCE,
            { LocalDate.of(2026, 9, 22) }, ZoneId.of("UTC"), nowSeconds = { 100 })
            .pushFreshAppend(PushAppendTable.HR_SAMPLE, "wearable")
        assertEquals(PushResult.NoData, result)
        assertTrue(transport.batches.isEmpty())
        assertNull(progress.pendingFreshBatch(PushAppendTable.HR_SAMPLE, "wearable"))
    }

    @Test fun wrongOwnerOrNonexactAckRetainsPendingAndNeverCommitsFreshCursor() = runBlocking {
        val batch = PushProtocol.appendBatch(PushAppendTable.HR_SAMPLE, SOURCE, "wearable", null,
            listOf(sample(1, 100)), fresh = true)
        val progress = MemoryProgress()
        progress.savePendingFreshBatch(PushAppendTable.HR_SAMPLE, "wearable", batch)
        val transport = AckingTransport { PushAck.fromBatch(it).copy(acceptedRows = 0) }
        val coordinator = PushCoordinator(FakePushSource(), transport, progress, SOURCE,
            { LocalDate.of(2026, 9, 22) }, ZoneId.of("UTC"))
        assertTrue(coordinator.pushFreshAppend(PushAppendTable.HR_SAMPLE, "wearable") is PushResult.Rejected)
        assertNull(progress.freshCursor(PushAppendTable.HR_SAMPLE, "wearable"))
        val wrongOwner = PushCoordinator(FakePushSource(), transport, progress,
            "00000000-0000-4000-8000-000000000011", { LocalDate.of(2026, 9, 22) }, ZoneId.of("UTC"))
        assertTrue(wrongOwner.pushFreshAppend(PushAppendTable.HR_SAMPLE, "wearable") is PushResult.Rejected)
        assertEquals(1, transport.batches.size)
        assertNotNull(progress.pendingFreshBatch(PushAppendTable.HR_SAMPLE, "wearable"))
    }

    @Test fun freshSelectionExcludesFutureAndOldRowsAndBoundsRequest() = runBlocking {
        val now = 20_000L
        val source = FakePushSource(append = mutableMapOf("hrSample|wearable" to
            (mutableListOf(sample(1, now - 301), sample(2, now + 1)) +
                (3L..300L).map { sample(it, now - 1) }).toMutableList()))
        val progress = MemoryProgress()
        val transport = AckingTransport()
        val result = PushCoordinator(source, transport, progress, SOURCE,
            { LocalDate.of(2026, 9, 22) }, ZoneId.of("UTC"), nowSeconds = { now })
            .pushFreshAppend(PushAppendTable.HR_SAMPLE, "wearable") as PushResult.Accepted
        assertEquals(128, result.recordCount)
        assertTrue(result.hasMore)
        assertEquals(130L, transport.batches.single().endCursor!!.rowId)
        assertTrue(transport.batches.single().body.size <= 64 * 1024)
        assertNull(progress.cursor(PushAppendTable.HR_SAMPLE, "wearable"))
    }

    @Test fun cycleCheckpointSurvivesSettingsRecreationAndKeepsFailureWithRotation() {
        val prefs = SelfHostedPushSettingsTest.FakePushPrefs()
        val settings = SelfHostedPushSettings.forTest(prefs)
        val failure = PushFailure(PushFailureCode.HTTP_SERVER, 503)
        settings.saveCycleCheckpoint("receiver-owner", 1, more = true,
            rejected = false, failure = failure, retryable = true)
        val restored = SelfHostedPushSettings.forTest(prefs)
        assertEquals(1, restored.nextDeviceIndex("receiver-owner"))
        assertTrue(restored.cycleNeedsAnotherPass("receiver-owner"))
        assertTrue(restored.cycleHadRetryableFailure("receiver-owner"))
        assertEquals(failure, restored.cycleFailure("receiver-owner"))
        assertFalse(restored.cycleHadRetryableFailure("another-owner"))
        restored.saveCycleCheckpoint("receiver-owner", 0, false, false, null, false)
        assertFalse(settings.cycleHadRetryableFailure("receiver-owner"))
        assertNull(settings.cycleFailure("receiver-owner"))
    }

    @Test fun restoredDatabaseRowidsCannotStrandCurrentFreshSamples() = runBlocking {
        val source = FakePushSource(append = mutableMapOf("hrSample|wearable" to mutableListOf(sample(1, 100))))
        val progress = MemoryProgress()
        progress.saveFreshCursor(PushAppendTable.HR_SAMPLE, "wearable", PushCursor(10_000, "f".repeat(64)))
        val transport = AckingTransport()
        val result = PushCoordinator(source, transport, progress, SOURCE,
            { LocalDate.of(2026, 9, 22) }, ZoneId.of("UTC"), nowSeconds = { 100 })
            .pushFreshAppend(PushAppendTable.HR_SAMPLE, "wearable")
        assertTrue(result is PushResult.Accepted)
        assertNull(transport.batches.single().startCursor)
        assertEquals(1L, progress.freshCursor(PushAppendTable.HR_SAMPLE, "wearable")!!.rowId)
        assertNull(progress.cursor(PushAppendTable.HR_SAMPLE, "wearable"))
    }

    private fun sample(row: Long, ts: Long) = PushAppendRecord(row, linkedMapOf("ts" to ts),
        linkedMapOf("bpm" to 62))

    private companion object { const val SOURCE = "00000000-0000-4000-8000-000000000010" }
}
