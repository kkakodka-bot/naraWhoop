package com.frwhoop.scoring

import org.junit.Assert.*
import org.junit.Test
import java.util.UUID
import java.nio.file.Files

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

    @Test fun nativeDistributionRequiresItsImmutableBundledRevision() {
        val absent = Files.createTempDirectory("scoring-native-identity-").resolve("release.sha")
        val valid = config.workerIdentity { ScoringConfig.packagedSourceRevision(absent) { "$revision\n" } }
        assertEquals(revision, valid.sourceRevision)
        for (bundled in listOf(null, "source_identity_unavailable", "b".repeat(40))) {
            val error = assertThrows(IllegalArgumentException::class.java) {
                config.workerIdentity { ScoringConfig.packagedSourceRevision(absent) { bundled } }
            }
            assertNull(error.cause)
        }
    }

    @Test fun anExistingImageMarkerNeverFallsBackToTheBundledRevision() {
        val marker = Files.createTempFile("scoring-image-identity-", ".sha")
        Files.writeString(marker, "b".repeat(40))
        var fallbackCalled = false
        assertThrows(IllegalArgumentException::class.java) {
            config.workerIdentity {
                ScoringConfig.packagedSourceRevision(marker) { fallbackCalled = true; revision }
            }
        }
        assertFalse(fallbackCalled)
        val directory = Files.createTempDirectory("scoring-invalid-image-marker-")
        assertThrows(IllegalArgumentException::class.java) {
            config.workerIdentity { ScoringConfig.packagedSourceRevision(directory) { revision } }
        }
    }
}
