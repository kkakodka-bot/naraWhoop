package com.frwhoop.scoring.derived

import java.time.Duration
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** One bounded retry lane; slow object storage never occupies the scoring claim loop. */
internal class ArchiveRetryWorker(interval: Duration,work: () -> Boolean,onError: (Exception) -> Unit,
                                  maximumBatchSize: Int = 32) : AutoCloseable {
    private val executor=Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task,"derived-archive-retry").apply { isDaemon=true }
    }
    init {
        require(interval.toMillis() in 1..600_000)
        require(maximumBatchSize in 1..128)
        executor.scheduleWithFixedDelay({
            // Drain available debt without an idle delay after every successful claim.
            // One worker and a finite batch keep storage failures/backlog independent of scoring.
            try {
                for (index in 0 until maximumBatchSize) {
                    if (Thread.currentThread().isInterrupted || !work()) break
                }
            } catch(error: Exception) { onError(error) }
        },0,interval.toMillis(),TimeUnit.MILLISECONDS)
    }
    override fun close() { executor.shutdownNow() }
}
