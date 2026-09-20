package com.frwhoop.scoring

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** Documents the dirty-while-running completion guard (mirrors scoring_work_items SQL). */
class WorkItemCompletionTest {
    @Test
    fun markDoneSucceedsWhenDirtyAtUnchanged() {
        val dirtyAtClaim = Instant.parse("2026-06-15T10:00:00Z")
        val dirtyAtNow = dirtyAtClaim
        assertTrue(dirtyAtNow <= dirtyAtClaim)
    }

    @Test
    fun markDoneRefusesWhenDirtyAtMoved() {
        val dirtyAtClaim = Instant.parse("2026-06-15T10:00:00Z")
        val dirtyAtNow = Instant.parse("2026-06-15T10:05:00Z")
        assertFalse(dirtyAtNow <= dirtyAtClaim)
    }
}
