package com.noop.analytics

import com.noop.data.Spo2Sample
import com.noop.data.V18AuxRow
import com.noop.data.RrInterval

/** Experimental raw candidates retain the native gates and never imply calibrated saturation. */
object ServerAuxiliaryMetrics {
    fun ceiling(sessions: List<DetectedSleep>, samples: List<Spo2Sample>) =
        AnalyticsEngine.nightlySpo2CeilingMean(sessions, samples)

    fun candidate(sessions: List<DetectedSleep>, samples: List<V18AuxRow>) =
        AnalyticsEngine.nightlySpo2CandidateMean(sessions, samples)

    fun hrvWindows(start: Long, end: Long, rr: List<RrInterval>, stages: List<StageSegment>) =
        SleepStager.sessionHrvWindows(start, end, rr, stages)
}
