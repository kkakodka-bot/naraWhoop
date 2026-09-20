package com.frwhoop.scoring

import com.frwhoop.scoring.derived.ArchiveRetryWorker
import org.junit.Assert.*
import org.junit.Test
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class ArchiveRetryWorkerTest {
    @Test fun slowArchiveRunsSeparatelyAndDoesNotCreateConcurrentBacklog() {
        val entered=CountDownLatch(1);val release=CountDownLatch(1);val done=CountDownLatch(1)
        val active=AtomicInteger();val maximum=AtomicInteger()
        ArchiveRetryWorker(Duration.ofMillis(1),work={
            maximum.accumulateAndGet(active.incrementAndGet(),::maxOf)
            entered.countDown()
            try { release.await(2,TimeUnit.SECONDS) } finally { active.decrementAndGet();done.countDown() }
            false
        },onError={ throw AssertionError(it) }).use {
            assertTrue(entered.await(2,TimeUnit.SECONDS))
            assertEquals(1,active.get()) // Caller remains runnable while storage is blocked.
            release.countDown();assertTrue(done.await(2,TimeUnit.SECONDS))
            assertEquals(1,maximum.get())
        }
    }
    @Test fun failedArchiveDoesNotKillIndependentRetryLane() {
        val attempts=AtomicInteger();val failures=AtomicInteger();val retried=CountDownLatch(1)
        ArchiveRetryWorker(Duration.ofMillis(1),work={
            if(attempts.incrementAndGet()==1) error("controlled object-store failure")
            retried.countDown()
            false
        },onError={ failures.incrementAndGet() }).use {
            assertTrue(retried.await(2,TimeUnit.SECONDS));assertEquals(1,failures.get())
        }
    }
    @Test fun readyBacklogDrainsWithoutWaitingForTheNextIdleInterval() {
        val attempts=AtomicInteger();val drained=CountDownLatch(1)
        ArchiveRetryWorker(Duration.ofMinutes(1),work={
            if(attempts.incrementAndGet()==5) { drained.countDown();false } else true
        },onError={ throw AssertionError(it) }).use {
            assertTrue("four ready archives must drain in the first cycle",drained.await(2,TimeUnit.SECONDS))
            assertEquals(5,attempts.get())
        }
    }
    @Test fun aContinuouslyReadyQueueCannotRunAnUnboundedBatch() {
        val attempts=AtomicInteger();val limit=CountDownLatch(1);val excess=CountDownLatch(1)
        ArchiveRetryWorker(Duration.ofMinutes(1),work={
            val attempt=attempts.incrementAndGet()
            if(attempt==3) limit.countDown()
            if(attempt>3) excess.countDown()
            true
        },onError={ throw AssertionError(it) },maximumBatchSize=3).use {
            assertTrue(limit.await(2,TimeUnit.SECONDS))
            // A fourth callback would happen immediately if the batch bound were absent.
            assertFalse(excess.await(100,TimeUnit.MILLISECONDS))
            assertEquals(3,attempts.get())
        }
    }
}
