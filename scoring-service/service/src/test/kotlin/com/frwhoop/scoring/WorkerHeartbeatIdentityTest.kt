package com.frwhoop.scoring

import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class WorkerHeartbeatIdentityTest {
    private val revision = "a".repeat(40)
    private val config = ScoringConfig("unused", "unused", "unused", "unused",
        workerInstanceId = UUID.randomUUID().toString(), workerSourceRevision = revision)

    @Test fun aRestartHasAnotherProcessIdentityButRetainsItsDeploymentAndSource() {
        val first = config.workerIdentity { "$revision\n" }
        val next = config.workerIdentity { revision }
        assertEquals(first.workerInstanceId, next.workerInstanceId)
        assertEquals(revision, first.sourceRevision)
        assertNotEquals(first.processInstanceId, next.processInstanceId)
    }

    @Test fun missingMalformedAndMismatchedIdentityFailClosedWithoutExposingValues() {
        for (candidate in listOf(config.copy(workerInstanceId = null),
            config.copy(workerInstanceId = "1-2-3-4-5"),
            config.copy(workerInstanceId = "00000000-0000-0000-0000-000000000000"),
            config.copy(workerInstanceId = "private-value"),
            config.copy(workerSourceRevision = null),
            config.copy(workerSourceRevision = "private-value"),
            config.copy(workerSourceRevision = "b".repeat(40)))) {
            val error = assertThrows(IllegalArgumentException::class.java) { candidate.workerIdentity { revision } }
            assertFalse(error.stackTraceToString().contains("private-value"))
        }
        val error = assertThrows(IllegalArgumentException::class.java) {
            config.workerIdentity { throw IllegalStateException("private-source-file-error") }
        }
        assertNull(error.cause)
        assertFalse(error.stackTraceToString().contains("private-source-file-error"))
    }

    @Test fun preflightRejectsMissingIdentityBeforeTryingAnyDatabaseOrHttp() {
        val error = assertThrows(RuntimePreflightCommand.Failure::class.java) {
            RuntimePreflightCommand.run(config.copy(workerInstanceId = null))
        }
        assertEquals(RuntimePreflightCommand.Stage.WORKER_IDENTITY, error.stage)
        assertNull(error.cause)
    }
}
