package com.frwhoop.scoring

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Harness complexity and identity controls, not production or physiological performance evidence. */
class WholeDaySwiftSelectionIndexTest {
    private fun row(id: String, ts: Long, user: String = "u", device: String = "d") = JSONObject()
        .put("id", id).put("ts", ts).put("userId", user).put("deviceId", device)

    @Test fun preservesOrderRepeatsAndScopeWithoutAdoptingForeignCollisions() {
        val raw = JSONArray().put(row("b", 2)).put(row("other-owner", 1, user = "foreign"))
            .put(row("a", 1)).put(row("other-device", 1, device = "foreign"))
        assertEquals(listOf("b", "a", "b"), WholeDaySwiftRunner.selectedRowIds(raw, "hr", "u", "d",
            listOf(listOf(2), listOf(1L), listOf(2L))).toList())
        assertThrows(IllegalStateException::class.java) {
            WholeDaySwiftRunner.selectedRowIds(raw, "hr", "u", "d", listOf(listOf(3L)))
        }
    }

    @Test fun requiresExactlyOneSelectedIdentityButRetainsUnusedDuplicateControl() {
        val raw = JSONArray().put(row("one", 1)).put(row("two", 2)).put(row("also-two", 2))
        assertEquals(listOf("one"), WholeDaySwiftRunner.selectedRowIds(raw, "hr", "u", "d", listOf(listOf(1))).toList())
        assertThrows(IllegalStateException::class.java) {
            WholeDaySwiftRunner.selectedRowIds(raw, "hr", "u", "d", listOf(listOf(2)))
        }
        assertThrows(IllegalArgumentException::class.java) {
            WholeDaySwiftRunner.selectedRowIds(raw, "hr", "u", "d", listOf(emptyList()))
        }
    }

    @Test fun rrAndEventKeysPreserveTheirNativeDiscriminators() {
        val rr = JSONArray().put(row("seq0", 1).put("rrMs", 900).put("seq", 0))
            .put(row("seq1", 1).put("rrMs", 900).put("seq", 1))
            .put(row("rr950", 1).put("rrMs", 950).put("seq", 1))
        assertEquals(listOf("rr950", "seq0", "seq1"), WholeDaySwiftRunner.selectedRowIds(rr, "rr", "u", "d",
            listOf(listOf(1L, 950, 1), listOf(1, 900L, 0), listOf(1, 900, 1L))).toList())
        val events = JSONArray().put(row("off", 1).put("kind", "off"))
            .put(row("on", 1).put("kind", "on"))
        assertEquals(listOf("on", "off"), WholeDaySwiftRunner.selectedRowIds(events, "events", "u", "d",
            listOf(listOf(1L, "on"), listOf(1L, "off"))).toList())
    }

    @Test fun missingFieldsNeverBecomeExplicitNullIdentities() {
        val missing = row("missing", 1)
        val explicitNull = row("explicit-null", 1).put("kind", JSONObject.NULL)
        assertEquals(listOf("explicit-null"), WholeDaySwiftRunner.selectedRowIds(
            JSONArray().put(missing).put(explicitNull), "events", "u", "d", listOf(listOf(1L, null))).toList())
        assertThrows(IllegalStateException::class.java) {
            WholeDaySwiftRunner.selectedRowIds(JSONArray().put(missing), "events", "u", "d", listOf(listOf(1L, null)))
        }
    }

    @Test fun denseIdentityExtractionReadsRowsLinearly() {
        var reads = 0
        val count = 28_800
        val raw = JSONArray()
        repeat(count) { index ->
            val row = object : JSONObject() {
                override fun opt(key: String?): Any? { reads += 1; return super.opt(key) }
            }.put("id", "r$index").put("ts", index.toLong()).put("userId", "u").put("deviceId", "d")
            raw.put(row)
        }
        val actual = WholeDaySwiftRunner.selectedRowIds(raw, "hr", "u", "d",
            (0 until count).reversed().map { listOf(it.toLong()) })
        assertEquals(count, actual.length())
        assertEquals("r28799", actual.getString(0)); assertEquals("r0", actual.getString(count - 1))
        assertTrue("fixture field reads must stay linear: $reads", reads <= count * 6)
    }
}
