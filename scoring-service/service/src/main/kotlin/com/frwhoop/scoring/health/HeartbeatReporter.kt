package com.frwhoop.scoring.health

import com.frwhoop.scoring.db.PostgresClient
import org.slf4j.LoggerFactory
import java.util.UUID

/** Records exact process progress and retains the older singleton for existing diagnostics. */
class HeartbeatReporter(
    private val db: PostgresClient,
    private val version: String,
    private val identity: WorkerHeartbeatIdentity,
) {
    private val log = LoggerFactory.getLogger(HeartbeatReporter::class.java)

    init {
        db.withConnection { connection ->
            connection.prepareStatement("""
                insert into public.physiology_worker_heartbeats
                    (worker_instance_id,process_instance_id,source_revision,algorithm_version)
                values(?,?,?,?)
            """.trimIndent()).use { statement ->
                statement.setObject(1, identity.workerInstanceId)
                statement.setObject(2, identity.processInstanceId)
                statement.setString(3, identity.sourceRevision)
                statement.setString(4, version)
                // Reusing a process identity must fail rather than inherit earlier progress.
                statement.executeUpdate()
            }
        }
    }

    fun recordPoll() = record("last_poll_at", null)

    fun recordScore(userId: UUID, day: String) {
        record("last_score_at", null)
        log.debug("scored {} {}", userId, day)
    }

    fun recordError(message: String) {
        val code = message.takeIf { it.matches(Regex("[A-Za-z][A-Za-z0-9_.:-]{0,127}")) }
            ?: "scoring_worker_error"
        record(null, code)
    }

    private fun record(timestampColumn: String?, errorCode: String?) {
        val progress = if (timestampColumn == null) "" else "$timestampColumn=clock_timestamp(),"
        db.withConnection { connection ->
            connection.autoCommit = false
            try {
                connection.prepareStatement("""
                    update public.physiology_worker_heartbeats set ${progress}last_error=?
                    where worker_instance_id=? and process_instance_id=?
                      and source_revision=? and algorithm_version=?
                """.trimIndent()).use { statement ->
                    statement.setString(1, errorCode)
                    statement.setObject(2, identity.workerInstanceId)
                    statement.setObject(3, identity.processInstanceId)
                    statement.setString(4, identity.sourceRevision)
                    statement.setString(5, version)
                    check(statement.executeUpdate() == 1) { "Scoring process heartbeat identity unavailable" }
                }
                connection.prepareStatement("""
                    update public.physiology_service_heartbeats set ${progress}last_error=?,version=? where id=1
                """.trimIndent()).use { statement ->
                    statement.setString(1, errorCode)
                    statement.setString(2, version)
                    statement.executeUpdate()
                }
                connection.commit()
            } catch (error: Exception) {
                runCatching { connection.rollback() }
                throw error
            } finally { connection.autoCommit = true }
        }
    }
}
