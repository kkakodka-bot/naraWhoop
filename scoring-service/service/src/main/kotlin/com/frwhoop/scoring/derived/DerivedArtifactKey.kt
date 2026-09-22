package com.frwhoop.scoring.derived

import java.util.UUID

/** Canonical B2 key for one scored day archive (json.zst). */
object DerivedArtifactKey {
    fun objectKey(userId: UUID, day: String, algorithmVersion: String): String {
        require(DAY_RE.matches(day)) { "day must be YYYY-MM-DD" }
        require(algorithmVersion.isNotBlank()) { "algorithmVersion required" }
        return "v3/derived/users/$userId/days/$day/$algorithmVersion.json.zst"
    }

    private val DAY_RE = Regex("^\\d{4}-\\d{2}-\\d{2}$")
}
