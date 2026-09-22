package com.frwhoop.scoring.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.analytics.DetectedSleep
import com.noop.analytics.SleepStager
import com.noop.analytics.SleepStagerV2
import com.noop.analytics.StageSegment

/** Pure application of the already as-of-selected input journal. Never writes raw/local outputs. */
object SleepEditResolver {
    data class Result(val sessions: List<DetectedSleep>, val identities: Map<SleepBounds,SleepIdentity>,
                      val naps: Map<SleepBounds,Boolean>, val gaps: List<String>)

    fun resolve(detected: List<DetectedSleep>, inputs: SignalSampleReader.DayInputs, useV2: Boolean): Result {
        val edits = inputs.history.sleepEdits.filterNot { it.deleted }.sortedByDescending { it.revision }
        val identities = linkedMapOf<SleepBounds,SleepIdentity>()
        val naps = linkedMapOf<SleepBounds,Boolean>()
        val supplied = mutableListOf<DetectedSleep>()
        val suppressed = mutableListOf<SleepBounds>()
        val gaps = linkedSetOf<String>()
        for (edit in edits) {
            val p = edit.payload
            val original = SleepBounds(p.getLong("originalStart"),p.getLong("originalEnd"))
            val bounds = SleepBounds(p.getLong("start"),p.getLong("end"))
            // Even a dismissed/unmatched edit retains suppression of its original detected key.
            suppressed += original
            if (p.getBoolean("dismissed")) continue
            if (supplied.any { overlaps(bounds,SleepBounds(it.start,it.end)) }) {
                gaps += "overlapping_sleep_edits_latest_revision_wins"
                continue
            }
            val stages = if (p.has("stages")) {
                val a = p.getJSONArray("stages")
                (0 until a.length()).map { i -> a.getJSONObject(i).let {
                    StageSegment(it.getLong("start"),it.getLong("end"),it.getString("stage"))
                } }
            } else restage(bounds,inputs,useV2)
            if (stages.isEmpty()) gaps += "edited_sleep_raw_staging_unavailable"
            val asleep = stages.filter { it.stage != "wake" }.sumOf { it.end-it.start }
            supplied += DetectedSleep(bounds.start,bounds.end,asleep.toDouble()/(bounds.end-bounds.start),
                stages,null,null,hrOnly=inputs.gravity.none { it.ts in bounds.start until bounds.end })
            identities[bounds] = SleepIdentity(original.start,original.end,edit.entity)
            naps[bounds] = p.getBoolean("isNap")
        }
        val kept = detected.filter { d ->
            val b = SleepBounds(d.start,d.end)
            suppressed.none { it.start==b.start || overlaps(it,b) } && supplied.none { overlaps(b,SleepBounds(it.start,it.end)) }
        }
        return Result((kept+supplied).sortedWith(compareBy({it.start},{it.end})),identities,naps,gaps.toList())
    }

    private fun overlaps(a: SleepBounds,b: SleepBounds) = a.start<b.end && b.start<a.end

    private fun restage(b: SleepBounds, inputs: SignalSampleReader.DayInputs, useV2: Boolean): List<StageSegment> {
        val hr = inputs.hr.filter { it.ts in b.start until b.end && it.bpm > 0 }
        val grav = inputs.gravity.filter { it.ts in b.start until b.end }
        // Both stagers have compatibility fallbacks which label missing inputs "light". Never invoke
        // those as evidence for a manually supplied interval with no raw observations.
        if (if (useV2) hr.size < 2 && grav.size < 2 else grav.size < 2) return emptyList()
        val staged = if (useV2) SleepStagerV2.stageSession(b.start,b.end,inputs.gravity,inputs.hr,inputs.rr,inputs.scoringResp)
            else SleepStager.stageSession(b.start,b.end,inputs.gravity,inputs.hr,inputs.rr,inputs.scoringResp)
        // Retain only observed 30-second epochs; do not tile a long missing tail/gap with the
        // stager's nearest class. Sparse timelines explicitly preserve holes in snapshot output.
        val observed = (hr.map { it.ts }+grav.map { it.ts }).map { Math.floorDiv(it-b.start,30L) }.toSet()
        val out = mutableListOf<StageSegment>()
        for (s in staged) {
            var t = maxOf(b.start,s.start)
            while (t<minOf(b.end,s.end)) {
                val epoch = Math.floorDiv(t-b.start,30L)
                val end = minOf(s.end,b.end,b.start+(epoch+1)*30)
                if (epoch in observed) {
                    val last = out.lastOrNull()
                    if (last?.end == t && last.stage == s.stage) last.end=end
                    else out += StageSegment(t,end,s.stage)
                }
                t=end
            }
        }
        return out
    }
}
