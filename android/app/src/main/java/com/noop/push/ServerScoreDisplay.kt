package com.noop.push

import android.content.Context

object ServerScoreDisplay {
    fun hrvRmssd(context: Context, day: String, overlay: ServerScoreDayCache?): Double? {
        if (!ServerScoringSettings.isEnabled(context) || overlay?.day != day) return null
        overlay.compute?.let { return ServerConsumerProjection.number(overlay, "hrv_rmssd_ms") }
        if (overlay.features["hrv"]?.isCanonicalAvailable != true) return null
        return overlay?.daily?.hrvRmssdMs
    }

    fun restingHr(context: Context, day: String, overlay: ServerScoreDayCache?): Int? {
        if (!ServerScoringSettings.isEnabled(context) || overlay?.day != day) return null
        overlay.compute?.let { return ServerConsumerProjection.number(overlay, "resting_hr_bpm")?.toInt() }
        if (overlay.features["hrv"]?.isCanonicalAvailable != true) return null
        return overlay?.daily?.restingHrBpm
    }

    fun sleepTotalMin(context: Context, day: String, overlay: ServerScoreDayCache?): Double? {
        if (!ServerScoringSettings.isEnabled(context) || overlay?.day != day) return null
        overlay.compute?.let { return ServerConsumerProjection.number(overlay, "sleep_total_min") }
        if (overlay.features["sleep"]?.isCanonicalAvailable != true) return null
        return overlay?.daily?.sleepTotalMin
    }

    fun recovery(context: Context, day: String, overlay: ServerScoreDayCache?): Double? {
        if (!ServerScoringSettings.isEnabled(context) || overlay?.day != day) return null
        overlay.compute?.let { return ServerConsumerProjection.number(overlay, "recovery") }
        if (overlay.features["hrv"]?.isCanonicalAvailable != true) return null
        return overlay?.daily?.recovery
    }

    fun strain(context: Context, day: String, overlay: ServerScoreDayCache?): Double? {
        if (!ServerScoringSettings.isEnabled(context) || overlay?.day != day) return null
        overlay.compute?.let { return ServerConsumerProjection.number(overlay, "strain") }
        if (overlay.features["hrv"]?.isCanonicalAvailable != true) return null
        return overlay?.daily?.strain
    }

    fun spo2(context: Context, day: String, overlay: ServerScoreDayCache?): Double? {
        if (!ServerScoringSettings.isEnabled(context) || overlay?.day != day) return null
        overlay.compute?.let { return ServerConsumerProjection.number(overlay, "spo2_pct") }
        if (overlay.features["hrv"]?.isCanonicalAvailable != true) return null
        return overlay?.daily?.spo2Pct
    }
}
