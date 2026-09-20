package com.frwhoop.scoring.derived

import java.util.UUID

/** Canonical B2 key for one scored day archive (json.zst). */
object DerivedArtifactKey {
    fun objectKey(userId: UUID, deviceId: UUID, day: String, algorithmVersion: String,
                  inputRevision: Long, contentHash: String): String {
        require(DAY_RE.matches(day)) { "day must be YYYY-MM-DD" }
        java.time.LocalDate.parse(day)
        require(Regex("[A-Za-z0-9._-]+").matches(algorithmVersion)) { "unsafe version key" }
        require(inputRevision >= 0 && Regex("[a-f0-9]{64}").matches(contentHash))
        return "v3/derived/users/$userId/devices/$deviceId/days/$day/$algorithmVersion/" +
            "revisions/$inputRevision/$contentHash.json.zst"
    }

    /** Legacy key remains readable by migration/retention tooling; new writes use the revision key. */
    fun objectKey(userId: UUID, day: String, algorithmVersion: String): String {
        require(DAY_RE.matches(day)) { "day must be YYYY-MM-DD" }
        require(algorithmVersion.isNotBlank()) { "algorithmVersion required" }
        return "v3/derived/users/$userId/days/$day/$algorithmVersion.json.zst"
    }

    private val DAY_RE = Regex("^\\d{4}-\\d{2}-\\d{2}$")
}
