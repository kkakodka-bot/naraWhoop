package com.noop.push

import org.junit.Assert.assertEquals
import org.junit.Test

class ServerResultPollBudgetTest {
    @Test fun repeatedPendingReadsCannotExtendTheForegroundBudget() {
        val budget = ServerResultPollBudget()
        fun interval(time: Long, identity: String = "owner-device-generation", pending: Boolean = true,
                     failed: Boolean = false, foreground: Boolean = true) =
            budget.interval(identity, pending, failed, foreground, time, 60_000)
        assertEquals(2_000, interval(100_000))
        assertEquals(2_000, interval(159_999))
        assertEquals(60_000, interval(160_000))
        assertEquals(60_000, interval(1_000_000))
        assertEquals(2_000, interval(1_000_000, identity = "replacement-device-generation"))
        assertEquals(60_000, interval(1_001_000, failed = true))
        assertEquals(60_000, interval(1_002_000, foreground = false))
        assertEquals(60_000, interval(1_003_000, pending = false))
    }
}
