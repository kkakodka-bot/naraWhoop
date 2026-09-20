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
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class ScoringPoller(
    private val config: ScoringConfig,
    private val inputs: ScoreInputProvider,
    private val queue: ScoringWorkQueue,
    private val scorer: DayScorer,
    private val writer: EngineIngestWriter,
    private val heartbeat: HeartbeatReporter,
    private val archiveOutbox: DerivedArchiveOutbox? = null,
) {
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
                    log.error("poll cycle failed: {}", err.message, err)
                    heartbeat.recordError(err.message ?: err.javaClass.simpleName)
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
            val attempted = queue.withInputGate(selected) { guard ->
                val item = queue.claimOne(selected.userId,selected.deviceId,selected.day)
                if (item != null) processWorkItem(item,guard)
                true
            }
            // A slow device must not stop other users from using an available worker.
            // Keep the bounded scan and acquire a gate before claiming any queued work.
            if (attempted == null) busyDevices.add(ScoringWorkQueue.DeviceKey(selected.userId,selected.deviceId))
        }
    }

    fun scoreDay(userId: UUID, deviceId: UUID, day: String) {
        queue.dirtyWorkItem(userId, deviceId, day)
        val candidate = ScoringWorkQueue.Candidate(userId,deviceId,day)
        val done = queue.withInputGate(candidate) { guard ->
            val item = queue.claimOne(userId, deviceId, day)
                ?: error("Replay revision is owned by another worker")
            processWorkItem(item,guard)
        }
        check(done == true) { "Replay did not finish publication; inspect the durable work status" }
    }

    private fun processWorkItem(item: ScoringWorkQueue.WorkItem, guard: ScoringInputGate.Guard): Boolean {
        val started = System.nanoTime()
        val leaseLost = AtomicBoolean(false)
        val renewal = Executors.newSingleThreadScheduledExecutor { task ->
            Thread(task, "scoring-lease-renewal").apply { isDaemon = true }
        }
        val periodMs = (queue.claimLease.toMillis() / 3).coerceAtLeast(100)
        renewal.scheduleAtFixedRate({
            try {
                if (!queue.renew(item)) leaseLost.set(true)
            } catch (err: Exception) {
                leaseLost.set(true)
                log.warn("lease renewal failed for run {}: {}", item.runId, err.message)
            }
        }, periodMs, periodMs, TimeUnit.MILLISECONDS)
        try {
            guard.requireActive()
            val inputs = inputs.loadDay(item.userId, item.day, item.deviceId, item.timezoneId)
            if (inputs == null) {
                queue.markWaiting(item, "no device/inputs")
                return false
            }
            // Empty inputs can be an intentional correction/deletion. Publish an unavailable
            // snapshot so an old generated episode cannot survive a tombstone or removed data.
            val bundle = scorer.score(inputs, config.algorithmVersion,item.inputRevision.toString(),
                shadowBudget = { guard.remainingDuration.minusSeconds(15) })
            check(!leaseLost.get()) { "Scoring lease was lost before publication" }
            guard.requireActive()
            writer.write(bundle, item,guard.remainingDuration)
            val durationMs = ((System.nanoTime() - started) / 1_000_000).toInt()
            val done = queue.markDone(item, durationMs)
            if (done) {
                heartbeat.recordScore(item.userId, item.day)
                log.info(
                    "scored {} {} {} (hr={}, rr={}, sleeps={}, {}ms)",
                    item.userId, item.deviceId, item.day, inputs.hr.size, inputs.rr.size,
                    bundle.result.sleepSessions.size, durationMs,
                )
            } else {
                log.info(
                    "completion fenced for {} {} {} because lease or revision changed",
                    item.userId, item.deviceId, item.day,
                )
            }
            return done
        } catch (err: Exception) {
            log.error(
                "score failed for {} {} {}: {}",
                item.userId, item.deviceId, item.day, err.message, err,
            )
            if (queue.markFailed(item, err.message ?: err.javaClass.simpleName)) {
                heartbeat.recordError(err.message ?: err.javaClass.simpleName)
            } else {
                log.info("discarded superseded scoring run {}", item.runId)
            }
            return false
        } finally {
            renewal.shutdownNow()
        }
    }

}
