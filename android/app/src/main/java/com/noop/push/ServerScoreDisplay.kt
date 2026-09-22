package com.noop.push

import android.content.Context

object ServerScoreDisplay {
    fun hrvRmssd(context: Context, day: String, overlay: ServerScoreDayCache?): Double? {
        if (!ServerScoringSettings.isEnabled(context)) return null
        return overlay?.daily?.hrvRmssdMs
    }

    fun restingHr(context: Context, day: String, overlay: ServerScoreDayCache?): Int? {
        if (!ServerScoringSettings.isEnabled(context)) return null
        return overlay?.daily?.restingHrBpm
    }

    fun sleepTotalMin(context: Context, day: String, overlay: ServerScoreDayCache?): Double? {
        if (!ServerScoringSettings.isEnabled(context)) return null
        return overlay?.daily?.sleepTotalMin
    }
}
