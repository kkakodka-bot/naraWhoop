package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.HistoricalEngineIngestWriter
import com.frwhoop.scoring.db.HistoricalScoringWorkQueue
import com.frwhoop.scoring.db.HistoricalSignalSampleReader
import com.frwhoop.scoring.db.HistoryCheckpointReader
import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.health.HeartbeatReporter
import org.slf4j.LoggerFactory
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** The history contract owns its checkpoint generation; physiology claims never enter this path. */
class HistoricalScoringPoller(
    private val db: PostgresClient,
    private val queue: HistoricalScoringWorkQueue,
    private val reader: HistoricalSignalSampleReader,
    private val heartbeat: HeartbeatReporter,
    private val maximumAttemptDuration: Duration = Duration.ofSeconds(90),
) {
    private val log = LoggerFactory.getLogger(HistoricalScoringPoller::class.java)
    private val checkpoints = HistoryCheckpointReader(db)
    private val scorer = HistoricalDayScorer()
    private val writer = HistoricalEngineIngestWriter(queue)

    init {
        require(queue.algorithmVersion == VERSION && queue.historyMode)
        require(maximumAttemptDuration.toMillis() in 100..105_000)
    }

    fun runForever(interval: Duration) {
        while (!Thread.currentThread().isInterrupted) {
            try { pollOnce() }
            catch (error: Exception) {
                if (error is ScoringPoller.UnresponsiveAttempt) throw error
                heartbeat.recordError("history_poll_${error.javaClass.simpleName}")
                log.warn("Historical poll failed: {}", error.javaClass.simpleName)
            }
            Thread.sleep(interval.toMillis())
        }
    }

    fun pollOnce(): Int {
        queue.maintain()
        heartbeat.recordPoll()
        var published = 0
        repeat(8) {
            val item = queue.claim() ?: return published
            if (process(item)) published++
        }
        return published
    }

    private fun process(item: HistoricalScoringWorkQueue.WorkItem): Boolean {
        val start = System.nanoTime()
        val deadline = start + maximumAttemptDuration.toNanos()
        val cancelled = AtomicBoolean(false)
        val stopped = CountDownLatch(1)
        val renewalOwner = AtomicReference<Thread>()
        fun requireActive() = check(!cancelled.get() && !Thread.currentThread().isInterrupted &&
            System.nanoTime() < deadline) { "history_attempt_cancelled" }
        val work = FutureTask {
            requireActive()
            val input = requireNotNull(reader.loadHistoricalDay(item.userId, item.day, item.deviceId)) {
                "history_owner_device_unavailable"
            }
            requireActive()
            val history = HistoricalStateMachine.prepare(input, checkpoints.load(item))
            requireActive()
            val bundle = scorer.score(input, item.algorithmVersion, history)
            requireActive()
            writer.write(item, bundle, (System.nanoTime() - start) / 1_000_000) != null
        }
        val attempt = Thread({ try { work.run() } finally { stopped.countDown() } }, "history-scoring-attempt")
            .apply { isDaemon = true }
        fun cancel() {
            cancelled.set(true)
            work.cancel(true)
            db.abortConnectionsOwnedBy(attempt)
        }
        val renewal = Executors.newSingleThreadScheduledExecutor { task ->
            Thread(task, "history-lease-renewal").apply { isDaemon = true; renewalOwner.set(this) }
        }
        val cadence = (queue.claimLease.toMillis() / 3).coerceAtLeast(100)
        renewal.scheduleAtFixedRate({
            if (!cancelled.get()) {
                try { if (System.nanoTime() >= deadline || !queue.renew(item)) cancel() }
                catch (_: Exception) { cancel() }
            }
        }, cadence, cadence, TimeUnit.MILLISECONDS)
        var failure: String? = null
        var done = false
        var interrupted = false
        try {
            attempt.start()
            done = work.get(maximumAttemptDuration.toMillis(), TimeUnit.MILLISECONDS)
            if (!done) failure = "history_publication_superseded"
        } catch (_: TimeoutException) { failure = "history_attempt_timeout" }
        catch (_: InterruptedException) { interrupted = true; failure = "history_attempt_cancelled" }
        catch (error: ExecutionException) { failure = "history_attempt_${error.cause?.javaClass?.simpleName ?: "failed"}" }
        catch (_: java.util.concurrent.CancellationException) { failure = "history_lease_lost" }
        finally {
            cancelled.set(true)
            renewal.shutdownNow()
            renewalOwner.get()?.let(db::abortConnectionsOwnedBy)
            if (failure != null) cancel()
        }
        try {
            // Never start a replacement job until the cancelled attempt has stopped, even when
            // failure bookkeeping itself cannot reach Postgres.
            if (!stopped.await(2, TimeUnit.SECONDS)) throw ScoringPoller.UnresponsiveAttempt()
            if (failure != null) {
                queue.markFailed(item, failure)
                heartbeat.recordError(failure)
            }
            if (done) heartbeat.recordScore(item.userId, item.day)
            return done
        } finally { if (interrupted) Thread.currentThread().interrupt() }
    }

    companion object { const val VERSION = "frwhoop-server-2-history" }
}
