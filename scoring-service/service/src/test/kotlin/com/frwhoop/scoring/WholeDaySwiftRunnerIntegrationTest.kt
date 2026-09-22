package com.frwhoop.scoring

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Tests the PG-backed harness itself; none of these synthetic controls count as Swift parity. */
class WholeDaySwiftRunnerIntegrationTest {
    @Test fun nullableWaistOnlyMatchesResolvedUnsetAndNeverDiscardsMeasuredWaist() {
        val unknown=WholeDaySwiftCorpusTest.syntheticCase()
        unknown.input.getJSONObject("profile").put("waistCm",JSONObject.NULL)
        WholeDaySwiftRunner().run(WholeDaySwiftCorpus.validate(unknown))
        assertSame(JSONObject.NULL,unknown.input.getJSONObject("profile").get("waistCm"))
        val measured=WholeDaySwiftCorpusTest.syntheticCase()
        measured.input.getJSONObject("profile").put("waistCm",85.0)
        measured.input.getJSONArray("journal").getJSONObject(0).getJSONObject("payload").put("waistCm",85.0)
        WholeDaySwiftRunner().run(WholeDaySwiftCorpus.validate(measured))
        measured.input.getJSONObject("profile").put("waistCm",JSONObject.NULL)
        assertTrue(assertThrows(AssertionError::class.java) {
            WholeDaySwiftRunner().run(WholeDaySwiftCorpus.validate(measured))
        }.message!!.contains("effectiveProfile.waistCm"))
    }

    @Test fun emptyCalendarUsesRealReaderAndLeavesPhysiologyMissing() {
        val case=WholeDaySwiftCorpusTest.syntheticCase()
        val actual=WholeDaySwiftRunner().run(case)
        WholeDaySwiftCorpus.compare(actual.getJSONObject("selection"),case.expected.getJSONObject("selection"),case.id)
        val daily=actual.getJSONObject("result").getJSONObject("daily")
        listOf("avgHrv","avgSdnn","restingHr","skinTempC","spo2Pct").forEach { assertTrue(it,daily.isNull(it)) }
        assertEquals(0,actual.getJSONObject("result").getJSONArray("sleep").length())
    }

    @Test fun serverBranchRunsHistoricalOrchestrationAndKeepsTrueDstBounds() {
        val runner=WholeDaySwiftRunner()
        val previous=WholeDaySwiftCorpusTest.syntheticCase("previous","2026-03-07","America/Los_Angeles").copy(mode="server_day")
        val before=runner.run(previous)
        val next=WholeDaySwiftCorpusTest.syntheticCase("next","2026-03-08","America/Los_Angeles").copy(mode="server_day")
        next.input.getJSONArray("history").put(previous.id)
        val actual=runner.run(next)
        val bounds=actual.getJSONObject("selection").getJSONObject("bounds")
        assertEquals(23*3600L,bounds.getLong("dayHi")-bounds.getLong("dayLo")+1)
        WholeDaySwiftCorpus.compare(actual.getJSONObject("history").getJSONObject("baselinesBefore"),
            before.getJSONObject("history").getJSONObject("baselinesAfter"),"ordered.baselines")
        assertEquals(setOf("metrics","details","charts","chartMetadata","capabilities","sleep","dependency"),actual.getJSONObject("snapshot").keySet())
        assertEquals(2,actual.getJSONObject("snapshot").getJSONObject("dependency").getInt("configurationRevision"))
    }

    @Test fun calendarReaderExcludesHistoricalCounterPredecessorWhileServerDayRetainsIt() {
        for (mode in listOf("kernel_calendar", "server_day")) {
            val case = WholeDaySwiftCorpusTest.syntheticCase().copy(mode = mode)
            val bounds = case.input.getJSONObject("bounds")
            val night = bounds.getLong("nightLo")
            val day = bounds.getLong("dayLo")
            val end = bounds.getLong("dayHi")
            val raw = case.input.getJSONObject("raw").getJSONArray("steps")
            fun row(id: String, ts: Long, counter: Int) = JSONObject()
                .put("id", id).put("userId", case.input.getString("userId"))
                .put("deviceId", case.input.getString("deviceId"))
                .put("ts", ts).put("counter", counter)
                .put("activityClass", JSONObject.NULL).put("provenance", JSONObject.NULL)
            raw.put(row("older", night - 2, 5)).put(row("predecessor", night - 1, 10))
                .put(row("night-start", night, 15)).put(row("day-start", day, 20))
                .put(row("day-end", end, 25)).put(row("future", end + 1, 30))
            val actual = WholeDaySwiftRunner().run(case)
            val selection = actual.getJSONObject("selection")
            val inWindow = listOf("night-start", "day-start", "day-end")
            val expected = if (mode == "server_day") listOf("predecessor") + inWindow else inWindow
            assertEquals(mode, expected, selection.getJSONObject("streams").getJSONArray("steps").toList())
            assertEquals(mode, listOf("day-start", "day-end"), selection.getJSONArray("daySteps").toList())
            assertEquals(1L, selection.getLong("profileRevision"))
            assertEquals(2L, selection.getLong("configurationRevision"))
            assertEquals(mode == "server_day", actual.has("snapshot"))
        }
    }

    @Test fun inputIdentitiesOwnerAndTimeAreActuallySelectedNotCopiedFromExpected() {
        val case=WholeDaySwiftCorpusTest.syntheticCase()
        val lo=case.input.getJSONObject("bounds").getLong("dayLo")
        val hi=case.input.getJSONObject("bounds").getLong("dayHi")
        val rows=case.input.getJSONObject("raw").getJSONArray("hr")
        fun row(id:String,ts:Long,owner:String=case.input.getString("userId"),device:String=case.input.getString("deviceId"))=
            JSONObject().put("id",id).put("userId",owner).put("deviceId",device).put("ts",ts).put("bpm",75)
        rows.put(row("current",lo)).put(row("future",hi+1))
            .put(row("foreign",lo,"10000000-0000-4000-8000-000000000002","20000000-0000-4000-8000-000000000002"))
        val actual=WholeDaySwiftRunner().run(case).getJSONObject("selection")
        assertEquals(listOf("current"),actual.getJSONObject("streams").getJSONArray("hr").toList())
        assertEquals(listOf("current"),actual.getJSONArray("dayHr").toList())
        assertThrows(AssertionError::class.java) { WholeDaySwiftCorpus.compare(actual,case.expected.getJSONObject("selection"),case.id) }
    }
}
