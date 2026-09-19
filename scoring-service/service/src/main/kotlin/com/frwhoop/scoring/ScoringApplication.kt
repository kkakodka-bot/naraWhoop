package com.frwhoop.scoring

import com.frwhoop.scoring.db.EngineIngestWriter
import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.db.SignalSampleReader
import com.frwhoop.scoring.derived.DerivedArtifactWriter
import com.frwhoop.scoring.derived.DerivedArchiveOutbox
import com.frwhoop.scoring.health.HeartbeatReporter
import com.frwhoop.scoring.scoring.DayScorer
import com.frwhoop.scoring.scoring.CanonicalScorePayload
import com.frwhoop.scoring.scoring.ScoringPoller
import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.b2.B2Config
import com.frwhoop.scoring.signals.PhysiologyShadowRunner
import com.frwhoop.scoring.signals.VerifiedModelJobAssembler
import com.frwhoop.scoring.signals.ModelWorkQueue
import com.frwhoop.scoring.signals.ModelQueueWorker
import com.frwhoop.scoring.signals.JdbcAcquisitionContractResolver
import org.slf4j.LoggerFactory
import java.util.UUID

private val log = LoggerFactory.getLogger("ScoringApplication")

fun main(args: Array<String>) {
    require(args.isEmpty() || args.contentEquals(arrayOf("--replay-day")) || args.contentEquals(arrayOf("--inventory-signals")) ||
        args.contentEquals(arrayOf("--archive-only")) || args.contentEquals(arrayOf("--models-only")) ||
        args.contentEquals(arrayOf("--activate-models"))) {
        "Use no arguments, --replay-day, --inventory-signals, --archive-only, --models-only, or --activate-models; commands cannot be combined"
    }
    if (args.contains("--inventory-signals")) {
        SignalInventoryCommand.run(System.getenv())
        return
    }
    if (args.contains("--models-only") || args.contains("--activate-models")) {
        val databaseUrl = requireNotNull(System.getenv("DATABASE_URL")) { "DATABASE_URL required" }
        val modelId = requireNotNull(System.getenv("PHYSIOLOGY_MODEL_ID")) { "PHYSIOLOGY_MODEL_ID required for isolated model commands" }
        PostgresClient(databaseUrl, queryTimeoutSeconds = 15).use { db ->
            val objects = B2Config.fromEnv()?.let { credentials ->
                val store = B2ObjectStore(credentials)
                object : B2ObjectStore.GetClient {
                    override fun getObject(key: String, maximumBytes: Int) = store.getObject(key, maximumBytes)
                }
            }
            val runner = PhysiologyShadowRunner.fromEnvironment(db.dataSource, objects,
                assembler = VerifiedModelJobAssembler(JdbcAcquisitionContractResolver(db.dataSource)), modelId = modelId)
            val queue = ModelWorkQueue(db)
            val model = runner.configuredModels().single { it.id == modelId }
            if (args.contains("--activate-models")) {
                val revision = queue.activate(model)
                log.info("Activated shadow model {} revision {}; historical backfill enqueued", model.id, revision)
            } else {
                val seconds = (System.getenv("MODEL_POLL_SECONDS")?.toLongOrNull() ?: 8L).also { require(it in 1..600) }
                ModelQueueWorker(queue, SignalSampleReader(db), runner, modelId,
                    abortInputs = db::abortActiveConnections).runForever(java.time.Duration.ofSeconds(seconds))
            }
        }
        return
    }
    val config = ScoringConfig.fromEnv()
    if (args.contains("--archive-only")) {
        val b2 = requireNotNull(config.b2Config) { "Archive-only mode requires B2 configuration" }
        PostgresClient(config.databaseUrl).use { db ->
            val outbox = DerivedArchiveOutbox(db, DerivedArtifactWriter(b2, config.supabaseUrl, config.serviceRoleKey))
            while (!Thread.currentThread().isInterrupted) {
                val processed = try { outbox.processOne() } catch (error: Exception) {
                    log.warn("Archive queue unavailable: {}", error.javaClass.simpleName)
                    false
                }
                if (!processed) Thread.sleep(config.pollInterval.toMillis())
            }
        }
        return
    }
    require(config.algorithmVersion == CanonicalScorePayload.ALGORITHM_VERSION) {
        "This build requires algorithm version ${CanonicalScorePayload.ALGORITHM_VERSION}; use the baseline build for rollback"
    }
    val db = PostgresClient(config.databaseUrl)
    val reader = SignalSampleReader(db)
    val queue = ScoringWorkQueue(db)
    // Model configuration, object retrieval and Python execution are absent from this process path.
    val scorer = DayScorer(PhysiologyShadowRunner())
    val writer = EngineIngestWriter(config.supabaseUrl, config.serviceRoleKey, config.ingestSecret)
    val derivedWriter = config.b2Config?.let {
        DerivedArtifactWriter(it, config.supabaseUrl, config.serviceRoleKey)
    }
    if (derivedWriter == null) {
        log.warn("B2 credentials missing — derived artifact lane disabled (scores still write to Postgres)")
    }
    val heartbeat = HeartbeatReporter(db, config.algorithmVersion)
    val archiveOutbox = derivedWriter?.let { DerivedArchiveOutbox(db, it) }
    val poller = ScoringPoller(config, reader, queue, scorer, writer, heartbeat, archiveOutbox)

    if (args.contains("--replay-day") || config.replayUserId != null) {
        val userId = UUID.fromString(config.replayUserId ?: error("REPLAY_USER_ID required for --replay-day"))
        val day = config.replayDay ?: error("REPLAY_DAY required for --replay-day")
        val deviceId = resolveReplayDeviceId(reader, userId, config.replayDeviceId)
        log.info("replay mode: user={} device={} day={}", userId, deviceId, day)
        poller.scoreDay(userId, deviceId, day)
        return
    }

    poller.runForever()
}

private fun resolveReplayDeviceId(
    reader: SignalSampleReader,
    userId: UUID,
    replayDeviceId: String?,
): UUID {
    if (!replayDeviceId.isNullOrBlank()) {
        return UUID.fromString(replayDeviceId)
    }
    val devices = reader.listDeviceIds(userId)
    return when (devices.size) {
        0 -> error("REPLAY_DEVICE_ID required — user has no devices")
        1 -> devices.single()
        else -> error(
            "REPLAY_DEVICE_ID required — user has ${devices.size} devices; " +
                "set REPLAY_DEVICE_ID to one of: ${devices.joinToString()}",
        )
    }
}
