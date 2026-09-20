package com.frwhoop.scoring.db

import java.util.UUID

/**
 * Narrow read surface for scoring inputs — the server-side stand-in for the on-device repository
 * calls that feed [com.noop.analytics.AnalyticsEngine.analyzeDay].
 */
interface ScoreInputProvider {
    fun loadDay(userId: UUID, day: String, deviceId: UUID): SignalSampleReader.DayInputs?

    /** Queue jobs retain the event-time zone even if the user's current profile later changes. */
    fun loadDay(userId: UUID, day: String, deviceId: UUID, timezoneId: String): SignalSampleReader.DayInputs? =
        loadDay(userId, day, deviceId)
}
