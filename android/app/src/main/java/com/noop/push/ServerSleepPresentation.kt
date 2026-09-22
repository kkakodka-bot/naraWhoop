package com.noop.push

/** One coherent server sleep result for consumers; never merged with locally detected sessions. */
data class ServerSleepPresentation(
    val day: String, val timezone: String, val sourceDeviceId: String, val algorithmVersion: String,
    val resultRevision: Long, val inputRevision: Long, val sessions: List<ScoreSleep>,
    val totalMinutes: Double?, val inBedMinutes: Double?, val awakeMinutes: Double?, val efficiency: Double?,
    val phase: String, val cached: Boolean, val pending: Boolean, val fetchedAt: Long?,
) {
    companion object {
        fun from(state: ServerSnapshotDayState): ServerSleepPresentation? {
            val snapshot = state.snapshot ?: return null
            if ("sleep_sessions" !in snapshot.capabilities) return null
            return ServerSleepPresentation(snapshot.day, snapshot.timezone, snapshot.sourceDeviceId, snapshot.algorithmVersion,
                snapshot.resultRevision, snapshot.inputRevision, if (snapshot.status == "no_data") emptyList() else snapshot.sleep,
                snapshot.value("sleep_total_min"), snapshot.value("sleep_in_bed_min"), snapshot.value("sleep_awake_min"),
                snapshot.value("sleep_efficiency"), state.phase, state.cached, state.pending, state.fetchedAt)
        }
    }
}
