package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.ScoringConfig
import com.frwhoop.scoring.db.EngineIngestWriter
import com.frwhoop.scoring.db.ScoreInputProvider
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.db.ScoringInputGate
import com.frwhoop.scoring.derived.DerivedArchiveOutbox
import com.frwhoop.scoring.derived.ArchiveRetryWorker
import com.frwhoop.scoring.health.HeartbeatReporter
import org.slf4j.LoggerFactory
import java.time.Duration
import java.util.UUID
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

class ScoringPoller(
    private val config: ScoringConfig,
    private val inputs: ScoreInputProvider,
    private val queue: ScoringWorkQueue,
    private val scorer: DayScorer,
    private val writer: EngineIngestWriter,
    private val heartbeat: HeartbeatReporter,
    private val archiveOutbox: DerivedArchiveOutbox? = null,
    private val maximumAttemptDuration: Duration = Duration.ofSeconds(90),
    private val cancellationGrace: Duration = Duration.ofSeconds(2),
) {
    init {
        require(maximumAttemptDuration.toMillis() in 100..105_000)
        require(cancellationGrace.toMillis() in 50..5_000)
    }
    class UnresponsiveAttempt : IllegalStateException("scoring_attempt_cancellation_failed")
    private val log = LoggerFactory.getLogger(ScoringPoller::class.java)
    // Continue the bounded scan across polls: a fixed prefix of busy devices must not
    // monopolize every cycle. This is only a scheduling cursor, never a progress watermark.
    private var scanAfter: ScoringWorkQueue.Cursor? = null

    fun runForever() {
        log.info("scoring poller started (interval={}s, version={})", config.pollInterval.seconds, config.algorithmVersion)
        val archive=archiveOutbox?.let { outbox -> ArchiveRetryWorker(config.pollInterval,
            work={ outbox.processOne() },
            onError={ log.warn("Archive queue unavailable: {}",it.javaClass.simpleName) }) }
        try {
            while (!Thread.currentThread().isInterrupted) {
                try {
                    pollOnce()
                } catch (err: Exception) {
                    if (err is UnresponsiveAttempt) throw err
                    log.error("poll cycle failed: {}", err.javaClass.simpleName)
                    heartbeat.recordError(err.javaClass.simpleName)
                }
                Thread.sleep(config.pollInterval.toMillis())
            }
        } finally { archive?.close() }
    }

    fun pollOnce() {
        heartbeat.recordPoll()
        val busyDevices = mutableSetOf<ScoringWorkQueue.DeviceKey>()
        repeat(8) {
            var candidate = queue.peekOne(excludedDevices=busyDevices,after=scanAfter)
            if(candidate == null && scanAfter != null) {
                // Input revisions may move jobs before the saved key. Wrapping also revisits
                // released gates and rows recreated after a restart/deletion; nothing is retired.
                scanAfter = null
                candidate = queue.peekOne(excludedDevices=busyDevices)
            }
            val selected = candidate ?: return
            // Advance even when the later claim loses a race or the device gate is busy.
            scanAfter = selected.cursor
            val attempted = processCandidate(selected)
            // A slow device must not stop other users from using an available worker.
            // Keep the bounded scan and acquire a gate before claiming any queued work.
            if (attempted == null) busyDevices.add(ScoringWorkQueue.DeviceKey(selected.userId,selected.deviceId))
        }
    }

    fun scoreDay(userId: UUID, deviceId: UUID, day: String) {
        queue.dirtyWorkItem(userId, deviceId, day)
        val candidate = ScoringWorkQueue.Candidate(userId,deviceId,day)
        val done = processCandidate(candidate)
        check(done == true) { "Replay did not finish publication; inspect the durable work status" }
    }

    internal fun processCandidate(candidate: ScoringWorkQueue.Candidate): Boolean? =
        queue.withInputGate(candidate) { guard ->
            val item = queue.claimOne(candidate.userId,candidate.deviceId,candidate.day)
            if (item == null) false else processWorkItem(item,guard)
        }

    private fun processWorkItem(item: ScoringWorkQueue.WorkItem, guard: ScoringInputGate.Guard): Boolean {
        val started = System.nanoTime()
        val budget = minOf(maximumAttemptDuration, guard.remainingDuration.minusSeconds(15))
        val deadline = started + budget.toNanos().coerceAtLeast(0)
        val cancelled = AtomicBoolean(false)
        val leaseLost = AtomicBoolean(false)
        val snapshotCaptured = AtomicBoolean(false)
        val finished = CountDownLatch(1)
        val renewalThread = AtomicReference<Thread>()
        fun requireActive() {
            check(!cancelled.get() && !leaseLost.get() && !Thread.currentThread().isInterrupted &&
                System.nanoTime() < deadline) { "scoring_attempt_cancelled" }
            if (!snapshotCaptured.get()) guard.requireActive()
        }
        val work = FutureTask {
            requireActive()
            val input = inputs.loadDay(item.userId, item.day, item.deviceId, item.timezoneId)
            requireActive()
            guard.releaseAfterSnapshot()
            snapshotCaptured.set(true)
            if (input == null) {
                queue.markWaiting(item, "no device/inputs")
                false
            } else {
                // Deleted inputs must still publish an unavailable snapshot instead of retaining old physiology.
                val bundle = scorer.score(input, config.algorithmVersion,item.inputRevision.toString(),
                    shadowBudget = { Duration.ofNanos((deadline-System.nanoTime()).coerceAtLeast(0)).minusSeconds(15) })
                requireActive()
                writer.write(bundle, item, Duration.ofNanos((deadline-System.nanoTime()).coerceAtLeast(0)))
                requireActive()
                queue.markDone(item, ((System.nanoTime()-started)/1_000_000).toInt())
            }
        }
        val attemptThread = Thread({ try { work.run() } finally { finished.countDown() } }, "scoring-attempt")
            .apply { isDaemon = true }
        fun cancelWork() {
            cancelled.set(true)
            work.cancel(true)
            queue.abortConnectionsOwnedBy(attemptThread)
        }
        val renewal = Executors.newSingleThreadScheduledExecutor { task ->
            Thread(task, "scoring-lease-renewal").apply { isDaemon = true; renewalThread.set(this) }
        }
        val periodMs = (queue.claimLease.toMillis() / 3).coerceAtLeast(100)
        renewal.scheduleAtFixedRate({
            if (cancelled.get() || System.nanoTime() >= deadline) return@scheduleAtFixedRate
            try {
                if (!queue.renew(item)) { leaseLost.set(true); cancelWork() }
            } catch (err: Exception) {
                leaseLost.set(true)
                log.warn("lease renewal failed for run {}: {}", item.runId, err.javaClass.simpleName)
                cancelWork()
            }
        }, periodMs, periodMs, TimeUnit.MILLISECONDS)
        var failure: String? = null
        var interrupted = false
        var done = false
        try {
            attemptThread.start()
            done = work.get((deadline-System.nanoTime()).coerceAtLeast(1), TimeUnit.NANOSECONDS)
        } catch (_: TimeoutException) {
            failure = "scoring_attempt_timeout"
        } catch (_: InterruptedException) {
            interrupted = true; failure = "scoring_attempt_cancelled"
        } catch (_: CancellationException) {
            failure = if (leaseLost.get()) "scoring_lease_lost" else "scoring_attempt_cancelled"
        } catch (error: ExecutionException) {
            failure = "scoring_attempt_${error.cause?.javaClass?.simpleName ?: "failed"}"
        } finally {
            // Stop and abort renewal before cancellation/finish so it cannot extend a timed-out claim.
            cancelled.set(true)
            renewal.shutdownNow()
            renewalThread.get()?.let(queue::abortConnectionsOwnedBy)
            if (failure != null) cancelWork()
        }
        try {
            val stopped = try { finished.await(cancellationGrace.toMillis(), TimeUnit.MILLISECONDS) }
            catch (_: InterruptedException) { interrupted = true; false }
            if (failure != null) {
                try {
                    if (queue.markFailed(item, failure)) heartbeat.recordError(failure)
                } catch (_: Exception) {
                    // Leave no renewing abandoned lease if durable retry cannot be recorded.
                    throw UnresponsiveAttempt()
                }
            }
            if (!stopped) throw UnresponsiveAttempt()
            if (done) {
                heartbeat.recordScore(item.userId, item.day)
                log.info("published scoring run {} ({}ms)", item.runId,
                    (System.nanoTime()-started)/1_000_000)
            }
            return done
        } finally { if (interrupted) Thread.currentThread().interrupt() }
    }

}
