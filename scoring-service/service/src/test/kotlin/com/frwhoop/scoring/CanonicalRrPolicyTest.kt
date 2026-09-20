package com.frwhoop.scoring

import com.frwhoop.scoring.db.CanonicalRrPolicy
import com.noop.data.RrInterval
import com.noop.protocol.DeviceFamily
import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Test

class CanonicalRrPolicyTest {
    @Test fun packetStoreServerOracleDoesNotReconvertTicks() {
        val cases = javaClass.getResourceAsStream("/rr_packet_store_server_oracle.json")!!
            .bufferedReader().use { JSONArray(it.readText()) }
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val values = case.getJSONArray("ms")
            val channel = case.getInt("channel")
            val occurrences = mutableMapOf<Int, Int>()
            val rows = (0 until values.length()).map { ordinal ->
                val value = values.getInt(ordinal)
                val seq = occurrences[value] ?: 0
                occurrences[value] = seq + 1
                RrInterval(deviceId = "device", ts = 1700000000, rrMs = value, seq = seq,
                    ord = ordinal, srcChannel = channel)
            }
            assertEquals(case.getString("name"), if (channel == 5) rows else emptyList<RrInterval>(),
                CanonicalRrPolicy.select(rows, DeviceFamily.WHOOP5))
        }
    }

    @Test fun sharedNativeStoreSourceOracle() {
        val fixture = javaClass.getResourceAsStream("/canonical_rr_source_oracle.json")!!
            .bufferedReader().use { JSONObject(it.readText()) }
        assertEquals(fixture.getString("version"), CanonicalRrPolicy.VERSION)
        val cases = fixture.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val case = cases.getJSONObject(i)
            val input = case.getJSONArray("rows")
            val rows = (0 until input.length()).map { j ->
                val row = input.getJSONArray(j)
                RrInterval(deviceId = "device", ts = row.getLong(0), rrMs = row.getInt(1),
                    seq = row.getInt(2), ord = if (row.isNull(3)) null else row.getInt(3),
                    srcChannel = if (row.isNull(4)) null else row.getInt(4),
                    tsSuspect = if (row.isNull(5)) null else row.getInt(5))
            }
            val indices = case.getJSONArray("expected")
            val expected = (0 until indices.length()).map { rows[indices.getInt(it)] }
            assertEquals(case.getString("name"), expected,
                CanonicalRrPolicy.select(rows, DeviceFamily.valueOf(case.getString("family"))))
        }
    }

    @Test fun hostedUntaggedMillisecondTrainIsScoredWhenNoWhoop5TransportExists() {
        val zero = RrInterval(deviceId = "device", ts = 100, rrMs = 800, seq = 0, ord = 0, srcChannel = 0)
        val unlabeled = RrInterval(deviceId = "device", ts = 101, rrMs = 810, seq = 0, ord = 0, srcChannel = null)
        assertEquals(listOf(zero, unlabeled), CanonicalRrPolicy.select(listOf(zero, unlabeled), DeviceFamily.WHOOP5))
        val realtime = unlabeled.copy(ts = 102, rrMs = 820, srcChannel = 6)
        assertEquals(emptyList<RrInterval>(), CanonicalRrPolicy.select(listOf(zero, unlabeled, realtime), DeviceFamily.WHOOP5))
        val historical = zero.copy(ts = 103, rrMs = 830, srcChannel = 5)
        assertEquals(listOf(historical), CanonicalRrPolicy.select(listOf(zero, unlabeled, historical), DeviceFamily.WHOOP5))
    }
}
