package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.DayResult
import com.noop.analytics.SleepStageTotals
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/** Shared by the live-day adapter and checkpoint codec so replay uses the same wall-hour policy. */
internal object HistoricalObservationWindows {
    fun hourlyHr(input: SignalSampleReader.DayInputs): List<HistoricalHourlyObservation> {
        val zone = ZoneId.of(input.timezone)
        return input.hr.filter { it.ts in input.dayLo..input.dayHi && it.bpm > 0 }.groupBy {
            Instant.ofEpochSecond(it.ts).atZone(zone).truncatedTo(ChronoUnit.HOURS).toEpochSecond()
        }.toSortedMap().map { (start, samples) ->
            HistoricalHourlyObservation(start, samples.map { it.bpm }.average(), samples.size)
        }
    }

    fun mainNightIndices(input: SignalSampleReader.DayInputs, result: DayResult,
                         habitualMidsleep: Long?, naps: Map<SleepBounds, Boolean>): Set<Int> {
        val candidates = result.sleepSessions.withIndex().filter {
            naps[SleepBounds(it.value.start, it.value.end)] != true
        }
        return SleepStageTotals.mainNightGroupIndices(candidates.map {
            SleepStageTotals.NightBlock(it.value.start, it.value.end)
        }, input.tzOffsetSeconds, habitualMidsleep, ZoneId.of(input.timezone))
            ?.map { candidates[it].index }?.toSet() ?: emptySet()
    }

    fun mainNight(input: SignalSampleReader.DayInputs, result: DayResult,
                  habitualMidsleep: Long?, naps: Map<SleepBounds, Boolean>): SleepBounds? {
        val group = mainNightIndices(input, result, habitualMidsleep, naps)
        val observed = result.sleepSessions.filterIndexed { index, s ->
            index in group && s.stages.any { it.end > it.start && it.stage in setOf("light", "deep", "rem") }
        }
        if (observed.isEmpty()) return null
        return SleepBounds(observed.minOf { it.start }, observed.maxOf { it.end })
    }
}
