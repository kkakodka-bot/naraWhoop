package com.noop.protocol

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.PI
import kotlin.math.sin

class W1PpgContributorsTest {
    private fun records(start: Long = 1_700_000_000, count: Int = 16) = (0 until count).map { second ->
        PpgHr.Record(start + second, second.toLong(), (0 until 24).map { sample ->
            (1000 * sin(2 * PI * (70.0 / 60) * (second * 24 + sample) / 24)).toInt()
        })
    }
    private fun legacy(records: List<PpgHr.Record>, subLag: Boolean = false) =
        PpgHr.estimate(records.flatMap { r -> r.samples.map { PpgHr.Sample(r.ts, it) } }, subLag)

    @Test fun recordingContributorsPreservesEveryExistingEstimateInBothModes() {
        for (subLag in listOf(false, true)) {
            val records = records().reversed()
            val observed = PpgHr.estimateRecords(records, subLag)
            assertTrue(observed.isNotEmpty())
            assertEquals(legacy(records, subLag), observed.map { it.estimate })
            observed.forEach { result ->
                val expected = records.filter { it.ts in result.estimate.ts - 4..result.estimate.ts + 4 }.sortedBy { it.ts }
                assertEquals(expected, result.records)
            }
        }
    }

    @Test fun duplicateSecondRetainsBothRecordsAndTheirEncounterOrder() {
        val base = records()
        val duplicate = base[8].copy(recordIndex = 4294967295, samples = base[8].samples.map { -it })
        for (input in listOf(base + duplicate, listOf(duplicate) + base)) {
            val observed = PpgHr.estimateRecords(input)
            assertEquals(legacy(input), observed.map { it.estimate })
            val selected = observed.single { it.estimate.ts == base[8].ts }.records
            assertEquals(input.filter { it.ts == duplicate.ts }, selected.filter { it.ts == duplicate.ts })
            assertEquals(10, selected.size) // Nine window seconds, including both records at the center.
        }
    }

    @Test fun gapsDoNotPullInAdjacentRunsAndEmptyRecordsDoNotContribute() {
        val first = records(count = 4)
        val second = records(start = first.last().ts + 2, count = 5)
        val input = first + PpgHr.Record(first.last().ts + 1, null, emptyList()) + second
        val observed = PpgHr.estimateRecords(input)
        assertEquals(legacy(input), observed.map { it.estimate })
        assertEquals(9, observed.size)
        observed.forEach { result ->
            assertEquals(if (result.estimate.ts <= first.last().ts) first else second, result.records)
        }
    }

    @Test fun contributingBytesAreFrozenAndUnknownIndexIsNotSynthesized() {
        val base = records(count = 4)
        val mutable = base[0].samples.toMutableList()
        val input = base.toMutableList().also { it[0] = it[0].copy(recordIndex = null, samples = mutable) }
        val observed = PpgHr.estimateRecords(input)
        assertTrue(observed.isNotEmpty())
        mutable[0] = -32768
        input.clear()
        observed.forEach { result ->
            assertNull(result.records.first().recordIndex)
            assertEquals(base.first().samples, result.records.first().samples)
        }
    }
}
