package com.noop.analytics

import com.noop.data.HrSample
import com.noop.data.SkinTempSample
import com.noop.protocol.DeviceFamily

/** Exposes the unchanged native temperature funnel after server sleep-boundary edits. */
object ServerSleepTemperature {
    fun mean(sessions: List<DetectedSleep>, hr: List<HrSample>, temperature: List<SkinTempSample>, family: DeviceFamily): Double? =
        AnalyticsEngine.wornNightlySkinTempC(sessions, hr, temperature, family)
}
