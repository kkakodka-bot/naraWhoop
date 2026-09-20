package com.frwhoop.scoring.health

import java.util.UUID

/** A deployment identity may survive Docker restarts; a process identity never does. */
data class WorkerHeartbeatIdentity(
    val workerInstanceId: UUID,
    val sourceRevision: String,
    val processInstanceId: UUID = UUID.randomUUID(),
) {
    init {
        require(workerInstanceId != UUID(0, 0) && processInstanceId != UUID(0, 0)) {
            "Invalid scoring worker identity"
        }
        require(sourceRevision.matches(Regex("[0-9a-f]{40}"))) { "Invalid scoring source revision" }
    }
}
