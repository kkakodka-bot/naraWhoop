package com.noop.ble

import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LiveCaptureQueueTest {
    private val a = BleCaptureIdentity("account-a", "generation-a", "source-a", "device-a", "session-a")
    private data class Packet(val identity: BleCaptureIdentity, val ordinal: Int)

    @Test fun onePacketThenSilenceCommitsAndWakesUploadWithoutAViewModel() = runTest {
        val persisted = mutableListOf<Packet>()
        var uploads = 0
        val queue = LiveCaptureQueue(backgroundScope, Packet::identity,
            persist = { persisted += it }, committed = { uploads++ }, blocked = { fail("blocked") },
            monotonicMs = { testScheduler.currentTime })
        val packet = Packet(a, 1)
        assertTrue(queue.offer(packet, 10))
        advanceTimeBy(749); runCurrent()
        assertTrue(persisted.isEmpty())
        advanceTimeBy(1); runCurrent()
        assertEquals(listOf(packet), persisted)
        assertEquals(1, uploads)
        assertEquals(0, queue.pendingCount)
    }

    @Test fun delayedIOKeepsOriginalAccountSourceDeviceSessionAndArrivalOrder() = runTest {
        val gate = CompletableDeferred<Unit>()
        val committed = mutableListOf<List<Packet>>()
        val queue = LiveCaptureQueue(backgroundScope, Packet::identity,
            persist = { if (it.first().ordinal == 1) gate.await(); committed += it },
            committed = {}, blocked = { fail("blocked") }, monotonicMs = { testScheduler.currentTime })
        queue.offer(Packet(a, 1), 10)
        advanceTimeBy(750); runCurrent()
        val b = a.copy(namespace = "b", sourceId = "b", deviceId = "b", sessionId = "b")
        queue.offer(Packet(b, 2), 10)
        gate.complete(Unit); runCurrent()
        assertEquals(listOf(listOf(Packet(a, 1)), listOf(Packet(b, 2))), committed)
    }

    @Test fun failedWriteRetriesSamePrefixWhileNewFramesWaitAndNoUploadPrecedesCommit() = runTest {
        var fail = true
        var uploads = 0
        val attempts = mutableListOf<List<Packet>>()
        val queue = LiveCaptureQueue(backgroundScope, Packet::identity,
            persist = { attempts += it; if (fail) throw IOException("disk pressure") },
            committed = { uploads++ }, blocked = {}, monotonicMs = { testScheduler.currentTime })
        queue.offer(Packet(a, 1), 10)
        advanceTimeBy(750); runCurrent()
        queue.offer(Packet(a, 2), 10)
        assertEquals(0, uploads)
        assertEquals(2, queue.pendingCount)
        fail = false
        advanceTimeBy(5_000); runCurrent()
        assertEquals(attempts[0], attempts[1])
        assertEquals(listOf(Packet(a, 2)), attempts[2])
        assertEquals(2, uploads)
        assertEquals(0, queue.pendingCount)
    }

    @Test fun capacityIncludesInflightAndDoesNotEvictAcceptedFrames() = runTest {
        val gate = CompletableDeferred<Unit>()
        var rejected = 0
        val persisted = mutableListOf<Packet>()
        val queue = LiveCaptureQueue(backgroundScope, Packet::identity,
            persist = { gate.await(); persisted += it }, committed = {}, blocked = { rejected++ },
            capacityRecords = 2, capacityBytes = 20, monotonicMs = { testScheduler.currentTime })
        queue.offer(Packet(a, 1), 10)
        advanceTimeBy(750); runCurrent()
        assertTrue(queue.offer(Packet(a, 2), 10))
        assertFalse(queue.offer(Packet(a, 3), 10))
        assertEquals(1, rejected)
        gate.complete(Unit); runCurrent()
        assertEquals(listOf(Packet(a, 1), Packet(a, 2)), persisted)
    }

    @Test fun repeatedArrivalsDoNotPostponeDeadlineAndConcurrentDrainsAreSerialized() = runTest {
        var commits = 0
        val queue = LiveCaptureQueue(backgroundScope, Packet::identity,
            persist = { commits++ }, committed = {}, blocked = { fail("blocked") },
            monotonicMs = { testScheduler.currentTime })
        repeat(5) { queue.offer(Packet(a, it), 10); advanceTimeBy(100) }
        advanceTimeBy(250); runCurrent()
        assertEquals(1, commits)
        val first = launch { queue.drain() }; val second = launch { queue.drain() }
        first.join(); second.join()
        assertEquals(1, commits)
        queue.stopAccepting()
        assertEquals(0, queue.pendingCount)
    }
    @Test fun sealedQueueRetriesAcceptedPrefixThenReleasesItsWriterJob() = runTest {
        val owner = SupervisorJob()
        val scope = CoroutineScope(owner + StandardTestDispatcher(testScheduler))
        var failing = true
        val persisted = mutableListOf<Packet>()
        val queue = LiveCaptureQueue(scope, Packet::identity,
            persist = { if (failing) throw IOException("held"); persisted += it },
            committed = {}, blocked = {}, batchRecords = 1,
            monotonicMs = { testScheduler.currentTime })
        try {
            assertTrue(queue.offer(Packet(a, 1), 10))
            queue.finishWhenDrained(); runCurrent()
            assertEquals(1, queue.pendingCount)
            assertTrue(owner.children.any { it.isActive })
            assertFalse(queue.offer(Packet(a, 2), 10))
            failing = false
            advanceTimeBy(5_000); runCurrent()
            assertEquals(listOf(Packet(a, 1)), persisted)
            assertEquals(0, queue.pendingCount)
            assertFalse(owner.children.any { it.isActive })
        } finally { scope.cancel() }
    }

}
