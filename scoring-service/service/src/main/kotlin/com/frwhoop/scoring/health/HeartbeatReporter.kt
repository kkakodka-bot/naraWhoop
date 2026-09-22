package com.frwhoop.scoring.health

import com.frwhoop.scoring.db.PostgresClient
import org.slf4j.LoggerFactory
import java.util.UUID

/** Records scorer liveness in the singleton scoring_service_heartbeats row. */
class HeartbeatReporter(
    private val db: PostgresClient,
    private val version: String,
) {
    private val log = LoggerFactory.getLogger(HeartbeatReporter::class.java)

    fun recordPoll(metrics: org.json.JSONObject = org.json.JSONObject()) {
        db.withConnection { conn ->
            conn.prepareStatement(
                """
                update public.scoring_service_heartbeats
                set last_poll_at = now(), version = ?, meta = ?::jsonb
                where id = 1
                """.trimIndent(),
            ).use { ps ->
                ps.setString(1, version)
                ps.setString(2, metrics.toString())
                ps.executeUpdate()
            }
        }
    }

    fun recordScore(userId: UUID, day: String) {
        db.withConnection { conn ->
            conn.prepareStatement(
                """
                update public.scoring_service_heartbeats
                set last_score_at = now(), version = ?, last_error = null
                where id = 1
                """.trimIndent(),
            ).use { ps ->
                ps.setString(1, version)
                ps.executeUpdate()
            }
        }
        log.debug("scored {} {}", userId, day)
    }

    fun recordError(message: String) {
        db.withConnection { conn ->
            conn.prepareStatement(
                """
                update public.scoring_service_heartbeats
                set last_error = ?
                where id = 1
                """.trimIndent(),
            ).use { ps ->
                ps.setString(1, message.take(2000))
                ps.executeUpdate()
            }
        }
    }
}
