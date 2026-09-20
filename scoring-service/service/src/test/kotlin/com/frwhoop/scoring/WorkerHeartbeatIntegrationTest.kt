package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.health.HeartbeatReporter
import com.frwhoop.scoring.health.WorkerHeartbeatIdentity
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.sql.SQLException
import java.time.Instant
import java.util.UUID

class WorkerHeartbeatIntegrationTest {
    private lateinit var db: PostgresClient
    private val version = "frwhoop-physiology-2"
    private val revision = "a".repeat(40)

    @Before fun setup() {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Requires disposable PostgreSQL queue harness", url != null)
        require(url!!.startsWith("postgresql://postgres@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db = PostgresClient(url, queryTimeoutSeconds = 5)
    }

    @After fun close() { if (::db.isInitialized) db.close() }

    @Test fun anotherDeploymentAndSingletonCannotSupplyTheCandidatesProgress() {
        val other = identity()
        val candidate = identity()
        val otherReporter = HeartbeatReporter(db, version, other)
        val candidateReporter = HeartbeatReporter(db, version, candidate)
        otherReporter.recordPoll()
        otherReporter.recordScore(UUID.randomUUID(), "2026-09-19")
        assertNotNull(snapshot(other).score)
        assertEquals(Progress(null, null, null), snapshot(candidate))
        assertEquals(1L, number("select count(*) from physiology_service_heartbeats where id=1 and last_poll_at is not null and last_score_at is not null"))
        candidateReporter.recordPoll()
        val observed = snapshot(candidate)
        assertNotNull(observed.poll)
        assertNull(observed.score)
        otherReporter.recordPoll()
        otherReporter.recordError("OtherWorkerError")
        assertEquals(observed, snapshot(candidate))
        assertEquals(0L, matching(candidate.copy(sourceRevision = "b".repeat(40))))
    }

    @Test fun restartCreatesAnEmptyNewProcessWithoutReusingPreviousBootProgress() {
        val first = identity()
        val original = HeartbeatReporter(db, version, first)
        original.recordPoll()
        original.recordScore(UUID.randomUUID(), "2026-09-19")
        val next = first.copy(processInstanceId = UUID.randomUUID())
        val restarted = HeartbeatReporter(db, version, next)
        assertEquals(Progress(null, null, null), snapshot(next))
        restarted.recordPoll()
        assertNotNull(snapshot(next).poll)
        assertNull(snapshot(next).score)
        assertNotNull(snapshot(first).score)
        assertEquals(2L, number("select count(*) from physiology_worker_heartbeats where worker_instance_id='${first.workerInstanceId}'"))
        val error = assertThrows(SQLException::class.java) { HeartbeatReporter(db, version, first) }
        assertEquals("23505", error.sqlState)
    }

    @Test fun sourceDeploymentProcessAndStartIdentityCannotBeRelabeled() {
        val id = identity()
        HeartbeatReporter(db, version, id)
        for (assignment in listOf("worker_instance_id='${UUID.randomUUID()}'",
            "process_instance_id='${UUID.randomUUID()}'", "source_revision='${"b".repeat(40)}'",
            "algorithm_version='frwhoop-server-1'", "started_at=started_at-interval '1 second'")) {
            val error = assertThrows(SQLException::class.java) { sql("update physiology_worker_heartbeats set $assignment where ${where(id)}") }
            assertEquals("23514", error.sqlState)
        }
        assertEquals(1L, matching(id))
    }

    @Test fun onlyServiceRoleCanReadAndUpdateProgressAndCannotRelabelOrDelete() {
        val id = identity()
        HeartbeatReporter(db, version, id)
        for (role in listOf("anon", "authenticated")) {
            for (statement in listOf("select * from physiology_worker_heartbeats", "update physiology_worker_heartbeats set last_error='Unauthorized'")) {
                val error = assertThrows(SQLException::class.java) { asRole(role, statement) }
                assertEquals("42501", error.sqlState)
            }
        }
        asRole("service_role", "select * from physiology_worker_heartbeats where ${where(id)}")
        asRole("service_role", "update physiology_worker_heartbeats set last_error='ServiceError' where ${where(id)}")
        assertEquals("ServiceError", snapshot(id).error)
        for (statement in listOf("delete from physiology_worker_heartbeats where ${where(id)}",
            "update physiology_worker_heartbeats set source_revision='${"b".repeat(40)}' where ${where(id)}")) {
            val error = assertThrows(SQLException::class.java) { asRole("service_role", statement) }
            assertEquals("42501", error.sqlState)
        }
    }

    @Test fun missingProcessRecordCannotAdvanceLegacySingletonAndErrorsAreSanitized() {
        val id = identity()
        val reporter = HeartbeatReporter(db, version, id)
        reporter.recordError("postgresql://private-user:private-secret@example.invalid/database")
        assertEquals("scoring_worker_error", snapshot(id).error)
        val before = text("select coalesce(last_poll_at::text,'') from physiology_service_heartbeats where id=1")
        sql("delete from physiology_worker_heartbeats where ${where(id)}")
        assertThrows(IllegalStateException::class.java) { reporter.recordPoll() }
        assertEquals(before, text("select coalesce(last_poll_at::text,'') from physiology_service_heartbeats where id=1"))
    }

    private data class Progress(val poll: Instant?, val score: Instant?, val error: String?)
    private fun identity() = WorkerHeartbeatIdentity(UUID.randomUUID(), revision)
    private fun where(id: WorkerHeartbeatIdentity) = "worker_instance_id='${id.workerInstanceId}' and process_instance_id='${id.processInstanceId}'"
    private fun matching(id: WorkerHeartbeatIdentity) = number("select count(*) from physiology_worker_heartbeats where ${where(id)} and source_revision='${id.sourceRevision}' and algorithm_version='$version'")
    private fun snapshot(id: WorkerHeartbeatIdentity): Progress = db.withConnection { connection ->
        connection.createStatement().use { statement ->
            statement.executeQuery("select last_poll_at,last_score_at,last_error from physiology_worker_heartbeats where ${where(id)}").use { rows ->
                check(rows.next())
                Progress(rows.getTimestamp(1)?.toInstant(), rows.getTimestamp(2)?.toInstant(), rows.getString(3))
            }
        }
    }
    private fun asRole(role: String, statement: String) = db.withConnection { connection ->
        connection.createStatement().use {
            try { it.execute("set role $role"); it.execute(statement) }
            finally { it.execute("reset role") }
        }
    }
    private fun sql(statement: String) = db.withConnection { connection -> connection.createStatement().use { it.execute(statement) } }
    private fun number(statement: String) = text(statement).toLong()
    private fun text(statement: String) = db.withConnection { connection -> connection.createStatement().use { query ->
        query.executeQuery(statement).use { rows -> check(rows.next()); rows.getString(1) }
    } }
}
