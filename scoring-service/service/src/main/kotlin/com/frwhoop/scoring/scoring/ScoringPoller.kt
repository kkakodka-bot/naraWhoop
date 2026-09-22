package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.ScoringConfig
import com.frwhoop.scoring.db.EngineIngestWriter
import com.frwhoop.scoring.db.LeaseHeartbeat
import com.frwhoop.scoring.db.ScoreInputProvider
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.db.HistoryCheckpointReader
import com.frwhoop.scoring.derived.SnapshotArchiveWorker
import com.frwhoop.scoring.health.HeartbeatReporter
import org.slf4j.LoggerFactory
import java.util.UUID

class ScoringPoller(
    private val config: ScoringConfig,
    private val inputs: ScoreInputProvider,
    private val queue: ScoringWorkQueue,
    private val scorer: DayScorer,
    private val writer: EngineIngestWriter,
    private val archiveWorker: SnapshotArchiveWorker?,
    private val heartbeat: HeartbeatReporter,
) {
    private val log = LoggerFactory.getLogger(ScoringPoller::class.java)

    fun runForever() {
        while (!Thread.currentThread().isInterrupted) {
            try { pollOnce() } catch (err: Exception) {
                log.error("poll failed: {}", err.javaClass.simpleName)
                heartbeat.recordError(err.javaClass.simpleName)
            }
            Thread.sleep(config.pollInterval.toMillis())
        }
    }

    fun pollOnce() {
        queue.maintain()
        heartbeat.recordPoll(queue.metrics())
        queue.claim()?.let(::processWorkItem)
        archiveWorker?.runOne()
    }

    /** Replay is a new generation and uses exactly the production publication fence. */
    fun scoreDay(userId: UUID, deviceId: UUID, day: String) {
        queue.maintain()
        queue.dirtyWorkItem(userId, deviceId, day)
        pollOnce()
        log.info("replay enqueued; normal queue scheduling and fencing apply")
    }

    fun processWorkItem(item: ScoringWorkQueue.WorkItem) {
        val started = System.nanoTime()
        try {
            LeaseHeartbeat(queue.claimLease) { queue.renew(item) }.use { lease ->
                val data = (if(item.historyGeneration == null) inputs.loadDay(item.userId, item.day, item.deviceId)
                    else inputs.loadHistoricalDay(item.userId,item.day,item.deviceId))
                    ?: error("device_or_profile_missing")
                val history = if(item.historyGeneration == null) null else
                    HistoricalStateMachine.prepare(data,HistoryCheckpointReader(queue.db).load(item))
                val bundle = scorer.score(data, item.algorithmVersion,history)
                lease.requireValid()
                val revision = writer.write(item, bundle, (System.nanoTime()-started)/1_000_000)
                if (revision == null) queue.markFailed(item, "input_revision_changed")
                else heartbeat.recordScore(item.userId, item.day)
            }
        } catch (err: Exception) {
            queue.markFailed(item, err.javaClass.simpleName)
            heartbeat.recordError(err.javaClass.simpleName)
            log.warn("score failed ({})", err.javaClass.simpleName)
        }
    }
}
