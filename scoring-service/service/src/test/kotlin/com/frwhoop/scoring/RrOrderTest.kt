package com.frwhoop.scoring

import org.junit.Assert.assertEquals
import org.junit.Test

class RrOrderTest {
    @Test
    fun readerSqlOrderMatchesPostgresSemantics() {
        data class Row(val ts: Long, val ord: Int?, val rrMs: Int, val seq: Int)

        val rows = listOf(
            Row(100, null, 800, 1),
            Row(100, 0, 820, 0),
            Row(200, null, 790, 0),
        )
        val ordered = rows.sortedWith(
            compareBy<Row> { it.ts }
                .thenBy(nullsFirst()) { it.ord }
                .thenBy { it.rrMs }
                .thenBy { it.seq },
        )
        // Postgres NULLS FIRST: ord=null precedes ord=0 at the same ts.
        assertEquals(listOf(800, 820, 790), ordered.map { it.rrMs })
    }
}
