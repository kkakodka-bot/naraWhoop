package com.noop.analytics

import com.noop.data.RrInterval

/**
 * Latest completed UTC five-minute measurement. Legacy coarse rows cannot prove continuity.
 *
 * Kotlin parity twin of `Packages/StrandAnalytics/.../CurrentHRV.swift`. Reuses [HrvAnalyzer] primitives only.
 */
object CurrentHrv {

    data class Snapshot(
        val rmssdMs: Double,
        val cleanBeats: Int,
        val coverage: Double,
        val computedAtUnix: Int,
    )

    /** Trailing window length (seconds) for the current HRV readout. */
    const val WINDOW_SECONDS: Int = HrvWindow.SECONDS

    /** Rows newer than this many seconds before `nowUnix` are treated as stale by the app-layer caller. */
    const val STALE_THRESHOLD_SECONDS: Int = 900

    /** Query the completed window's seconds, never the trailing partial window containing now. */
    fun completedWindow(nowUnix: Int): IntRange {
        val end = HrvWindow.alignedStart(nowUnix)
        return (end - HrvWindow.SECONDS) until end
    }

    /**
     * Compatibility entry point: no beat identities or acquisition spans can be recovered from
     * this row shape. Retains null until ingestion supplies proven observations.
     */
    fun derive(
        rows: List<RrInterval>,
        nowUnix: Int,
        windowSeconds: Int = WINDOW_SECONDS,
    ): Snapshot? {
        if (windowSeconds != HrvWindow.SECONDS) return null
        return deriveObservations(PhysiologyQuality.legacy(rows, "legacy-unscoped"), nowUnix)
    }

    /** The latest completed UTC window, never pooled with a previous sparse window. */
    fun deriveObservations(observations: List<PhysiologyQuality.IntervalObservation>, nowUnix: Int,
                           policy: HrvWindow.Policy = HrvWindow.Policy(), inputRevision: String = "unversioned"): Snapshot? {
        val result = HrvWindow.measure(completedWindow(nowUnix).first,
            observations, policy = policy, inputRevision = inputRevision, computationMode = "causal")
        val rmssd = result.observedRMSSD ?: return null
        if (!result.measurementValid) return null
        return Snapshot(rmssd, Math.round(result.validIntervalFraction * result.originalIds.size).toInt(),
            result.observedTimeFraction, nowUnix)
    }
}
