package com.noop.push

import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ServerScoringRescoreSkipTest {
    private val context = SelfHostedPushSettingsTest.FakePushPrefs()

    @Before
    fun setUp() {
        ServerScoringSettings.setEnabled(context, false)
        ServerScoringSettings.markOverlayLive(context, false)
    }

    @After
    fun tearDown() {
        ServerScoringSettings.setEnabled(context, false)
        ServerScoringSettings.markOverlayLive(context, false)
    }

    @Test
    fun liveServerOverlayDoesNotSuppressLocalOnlyMetrics() {
        ServerScoringSettings.setEnabled(context, true)
        assertFalse(ServerScoringSettings.skipsSyncCoupledRescore(context))
        ServerScoringSettings.markOverlayLive(context, true)
        assertFalse(ServerScoringSettings.skipsSyncCoupledRescore(context))
    }

    @Test
    fun runsSyncCoupledRescoreWhenFlagOff() {
        assertFalse(ServerScoringSettings.skipsSyncCoupledRescore(context))
    }

    @Test
    fun staleServerSnapshotIsNotLive() {
        val feature = ServerScoreFeatureCache("available", null, "device", "frwhoop-server-1",
            1L, 1L, null, null, null, null, null)
        val cache = ServerScoreDayCache("2026-09-18", "per_feature",
            ServerScoreDailyCache(hrvRmssdMs = 42.0), emptyList(), null, false, 0L,
            features = mapOf("hrv" to feature))
        assertTrue(ServerScoringSettings.overlayIsLive(cache))
        assertFalse(ServerScoringSettings.overlayIsLive(cache.copy(stale = true)))
        assertFalse(ServerScoringSettings.overlayIsLive(cache.copy(
            features = mapOf("hrv" to feature.copy(status = "stale")))))
    }

    @Test
    fun pushIntervalsMatchSpec() {
        assertTrue(ServerScoringSettings.IDLE_PUSH_INTERVAL_MS in 30_000L..60_000L)
        assertTrue(ServerScoringSettings.SYNC_PUSH_INTERVAL_MS <= 10_000L)
    }
}
