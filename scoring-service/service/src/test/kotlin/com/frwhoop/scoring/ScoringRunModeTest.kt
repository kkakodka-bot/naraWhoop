package com.frwhoop.scoring

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ScoringRunModeTest {
    private val config = ScoringConfig(
        databaseUrl = "postgresql://localhost/unused",
        ingestSecret = "test-only",
        supabaseUrl = "https://example.invalid/rest/v1",
        serviceRoleKey = "test-only",
    )

    @Test
    fun noArgumentsRemainPersistentWithCompletePartialBlankOrInvalidReplayEnvironment() {
        for (stale in listOf(
            config,
            config.copy(replayUserId = "00000000-0000-0000-0000-000000000001", replayDay = "2026-09-18"),
            config.copy(replayUserId = ""),
            config.copy(replayUserId = "invalid", replayDay = "invalid", replayDeviceId = "invalid"),
            config.copy(replayDay = "2026-09-18"),
        )) {
            assertEquals(ScoringRunMode.PERSISTENT, stale.runMode(emptyArray()))
        }
    }

    @Test
    fun oneShotReplayRequiresAnExplicitFlagAndRequiredInputs() {
        val valid = config.copy(replayUserId = "00000000-0000-0000-0000-000000000001", replayDay = "2026-09-18")
        assertEquals(ScoringRunMode.REPLAY, valid.runMode(arrayOf("--replay-day")))
        for (missing in listOf(config, valid.copy(replayUserId = " "), valid.copy(replayDay = ""))) {
            assertThrows(IllegalArgumentException::class.java) { missing.runMode(arrayOf("--replay-day")) }
        }
    }

    @Test
    fun readOnlyAndArchiveCommandsRemainExplicitEvenWithStaleReplayEnvironment() {
        val stale = config.copy(replayUserId = "invalid")
        assertEquals(ScoringRunMode.INVENTORY, stale.runMode(arrayOf("--inventory-signals")))
        assertEquals(ScoringRunMode.ARCHIVE_ONLY, stale.runMode(arrayOf("--archive-only")))
        assertEquals(ScoringRunMode.CHECK_CONFIG, stale.runMode(arrayOf("--check-config")))
        assertEquals(ScoringRunMode.MODELS_ONLY, stale.runMode(arrayOf("--models-only")))
        assertEquals(ScoringRunMode.ACTIVATE_MODELS, stale.runMode(arrayOf("--activate-models")))
    }

    @Test
    fun unknownAndCombinedCommandsAreRejected() {
        for (args in listOf(arrayOf("--unknown"), arrayOf("--replay-day", "--archive-only"),
            arrayOf("--models-only","--replay-day"),arrayOf("--check-config","--activate-models"))) {
            assertThrows(IllegalArgumentException::class.java) { config.runMode(args) }
        }
    }
}
