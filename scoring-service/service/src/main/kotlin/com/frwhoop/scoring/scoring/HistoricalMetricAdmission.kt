package com.frwhoop.scoring.scoring

import com.noop.analytics.BaselineState
import com.noop.data.DailyMetric
import java.time.LocalDate
import java.time.ZoneOffset

/** Admission views never mutate the checkpoint observations or their historical chart values. */
internal class HistoricalMetricAdmission(private val prepared: HistoricalStateMachine.Prepared, current: DailyMetric) {
    companion object {
        fun eligible(day: String, metric: String, epochs: Map<String, Double>, before: Map<String, BaselineState>,
                     requireUsable: Boolean = true): Boolean {
            val epoch = epochs[metric]?.takeIf { it.isFinite() && it >= 0 } ?: return false
            return LocalDate.parse(day).atStartOfDay(ZoneOffset.UTC).toEpochSecond() >= epoch &&
                (!requireUsable || before[metric]?.usable == true)
        }
    }

    private fun admitted(row: DailyMetric, method: String): DailyMetric {
        fun keep(key: String, usable: Boolean = true) = eligible(row.day, key, prepared.baselineEpochSeconds, prepared.baselines, usable)
        return row.copy(
            avgHrv = row.avgHrv.takeIf { keep("hrv") },
            restingHr = row.restingHr.takeIf { keep("resting_hr") },
            respRateBpm = row.respRateBpm.takeIf { keep("resp") },
            strain = row.strain.takeIf { keep("strain", false) && method == prepared.effortMethod },
            totalSleepMin = row.totalSleepMin.takeIf { keep("resting_hr", false) },
            steps = row.steps.takeIf { keep("resting_hr", false) },
        )
    }

    val rows: List<DailyMetric> = prepared.history.filter { it.getString("sourceEra") == prepared.sourceEra }.map { row ->
        val daily = DailyMetricJson.decode(row.getJSONObject("daily"))
        require(daily.day == row.getString("day") && daily.day < current.day && daily.deviceId == current.deviceId)
        admitted(daily, row.getString("effortMethod"))
    } + admitted(current, prepared.effortMethod)
    val today: DailyMetric get() = rows.last()
    private val byDay = rows.associateBy { it.day }

    fun window(days: Int, includeToday: Boolean = true): List<DailyMetric> {
        require(days > 0)
        val end = LocalDate.parse(today.day).minusDays(if (includeToday) 0 else 1)
        return (days - 1 downTo 0).map { back ->
            val key = end.minusDays(back.toLong()).toString()
            byDay[key] ?: DailyMetric(today.deviceId, key)
        }
    }

    fun readinessRows(): List<DailyMetric> = window(31).map { row ->
        row.copy(avgHrv = row.avgHrv.takeIf {
            eligible(row.day, "readiness_hrv_ln", prepared.baselineEpochSeconds, prepared.baselines)
        })
    }
}
