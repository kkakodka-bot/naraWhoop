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
    val requestedMode = ScoringConfig.runModeFromArgs(args)
    if (requestedMode == ScoringRunMode.INVENTORY) {
        SignalInventoryCommand.run(System.getenv())
        return
    }
    if (requestedMode in setOf(ScoringRunMode.MODELS_ONLY,ScoringRunMode.ACTIVATE_MODELS)) {
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
            if (requestedMode == ScoringRunMode.ACTIVATE_MODELS) {
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
    val mode = config.runMode(args)
    if (mode == ScoringRunMode.CHECK_CONFIG) {
        println(RuntimePreflightCommand.run(config))
        return
    }
    if (mode == ScoringRunMode.HISTORY) {
        require(config.algorithmVersion == com.frwhoop.scoring.scoring.HistoricalScoringPoller.VERSION)
        val identity = config.workerIdentity()
        PostgresClient(config.databaseUrl, queryTimeoutSeconds = 15).use { db ->
            val store = config.b2Config?.let(::B2ObjectStore)
            val objects = store?.let { B2ObjectStore.ReadClient(it::readObject) }
            val reader = com.frwhoop.scoring.db.HistoricalSignalSampleReader(db,
                com.frwhoop.scoring.db.AuxiliaryObjectReader(objects))
            val queue = com.frwhoop.scoring.db.HistoricalScoringWorkQueue(db, config.algorithmVersion)
            val heartbeat = HeartbeatReporter(db, config.algorithmVersion, identity)
            val archive = if (store == null) null else com.frwhoop.scoring.derived.SnapshotArchiveWorker(db,
                object : B2ObjectStore.PutClient {
                    override fun putObject(key: String, body: ByteArray, contentType: String) =
                        store.putObject(key, body, contentType)
                }, requireNotNull(config.b2Config).bucket)
            val retry = archive?.let {
                com.frwhoop.scoring.derived.ArchiveRetryWorker(config.pollInterval, it::runOne,
                    onError = { error -> log.warn("Historical archive retry failed: {}", error.javaClass.simpleName) })
            }
            try {
                ScoringWorkerProcess.run {
                    com.frwhoop.scoring.scoring.HistoricalScoringPoller(db, queue, reader, heartbeat)
                        .runForever(config.pollInterval)
                }
            } finally { retry?.close() }
        }
        return
    }
    if (mode == ScoringRunMode.PERSISTENT &&
        listOf(config.replayUserId, config.replayDay, config.replayDeviceId).any { it != null }) {
        log.warn("Ignoring REPLAY_* environment in persistent mode; use --replay-day for an explicit one-shot replay")
    }
    if (mode == ScoringRunMode.ARCHIVE_ONLY) {
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
    val workerIdentity = config.workerIdentity()
    val db = PostgresClient(config.databaseUrl, queryTimeoutSeconds = 15)
    val reader = SignalSampleReader(db)
    val queue = ScoringWorkQueue(db)
    // Optional bounded raw extraction has its own executor. Model configuration/Python remain isolated.
    val rawLane = com.frwhoop.scoring.signals.BoundedRawFeatureLane(config.b2Config?.let { credentials ->
        val store = B2ObjectStore(credentials)
        object : B2ObjectStore.GetClient { override fun getObject(key: String,maximumBytes: Int) = store.getObject(key,maximumBytes) }
    })
    val scorer = DayScorer(PhysiologyShadowRunner(),rawLane)
    val writer = EngineIngestWriter(config.supabaseUrl, config.serviceRoleKey, config.ingestSecret)
    val derivedWriter = config.b2Config?.let {
        DerivedArtifactWriter(it, config.supabaseUrl, config.serviceRoleKey)
    }
    if (derivedWriter == null) {
        log.warn("B2 credentials missing — derived artifact lane disabled (scores still write to Postgres)")
    }
    val heartbeat = HeartbeatReporter(db, config.algorithmVersion, workerIdentity)
    val archiveOutbox = derivedWriter?.let { DerivedArchiveOutbox(db, it) }
    val computePublisher = com.frwhoop.scoring.db.ComputeContractPublisher(db)
    val poller = ScoringPoller(config, reader, queue, scorer, writer, heartbeat, archiveOutbox,
        publishComputeDispositions = {
            try { computePublisher.publishDay(it) }
            catch (error: Exception) { log.warn("Compute disposition deferred: {}", error.javaClass.simpleName) }
        })
    val sessionWorker = com.frwhoop.scoring.derived.ArchiveRetryWorker(config.pollInterval,
        work = computePublisher::processSession,
        onError = { log.warn("Compute session request unavailable: {}", it.javaClass.simpleName) })
    val dispositionRetry = com.frwhoop.scoring.derived.ArchiveRetryWorker(config.pollInterval,
        work = computePublisher::retryDay,
        onError = { log.warn("Compute disposition retry unavailable: {}", it.javaClass.simpleName) })

    try {
        ScoringWorkerProcess.run {
            if (mode == ScoringRunMode.REPLAY) {
                val userId = UUID.fromString(config.replayUserId ?: error("REPLAY_USER_ID required for --replay-day"))
                val day = config.replayDay ?: error("REPLAY_DAY required for --replay-day")
                val deviceId = resolveReplayDeviceId(reader, userId, config.replayDeviceId)
                log.info("Explicit one-shot replay requested")
                poller.scoreDay(userId, deviceId, day)
            } else poller.runForever()
        }
    } finally {
        sessionWorker.close()
        dispositionRetry.close()
        rawLane.close()
        db.close()
    }
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
            "REPLAY_DEVICE_ID required — user has ${devices.size} devices; select an owned device explicitly",
        )
    }
}
