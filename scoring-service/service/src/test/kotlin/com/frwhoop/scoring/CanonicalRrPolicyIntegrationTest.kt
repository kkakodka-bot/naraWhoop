package com.frwhoop.scoring

import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.data.RrInterval
import com.noop.protocol.RrSourceChannel
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import java.nio.file.Files
import java.sql.Connection
import java.sql.PreparedStatement
import java.util.UUID

class CanonicalRrPolicyIntegrationTest : PgIntegrationBase() {
    private data class Beat(
        val ts: Long = 100, val rr: Int = 800, val seq: Int = 0, val ord: Int? = null,
        val channel: Int? = null, val suspect: Int? = null,
        val owner: UUID? = null, val sourceDevice: UUID? = null,
    )

    private data class IntendedPolicyDifference(val historical: List<RrInterval>, val current: List<RrInterval>)

    private fun expectedRows(vararg rows: Beat): List<RrInterval> = rows.map { r ->
        RrInterval((r.sourceDevice ?: device).toString(), r.ts, r.rr, r.seq,
            ord = r.ord, srcChannel = r.channel, tsSuspect = r.suspect)
    }

    private fun family(value: String?) = pg.connection().use { c ->
        c.prepareStatement("update devices set device_family=? where id=?").use { s ->
            s.setString(1, value); s.setObject(2, device); s.executeUpdate()
        }
    }

    private fun insert(vararg rows: Beat) = pg.connection().use { c ->
        c.prepareStatement("""insert into noop_rr_intervals
            (user_id,device_id,source_id,ts,"rrMs",seq,ord,"srcChannel","tsSuspect",batch_id)
            values(?,?,?,?,?,?,?,?,?,?)""").use { s ->
            for (r in rows) {
                s.setObject(1, r.owner ?: u); s.setObject(2, r.sourceDevice ?: device); s.setObject(3, u)
                s.setLong(4, r.ts); s.setInt(5, r.rr); s.setInt(6, r.seq); s.setObject(7, r.ord)
                s.setObject(8, r.channel); s.setObject(9, r.suspect); s.setObject(10, u); s.addBatch()
            }
            s.executeBatch()
        }
    }

    private fun bind(s: PreparedStatement, owner: UUID, source: String, lo: Long, hi: Long, old: Boolean) {
        s.setObject(1, owner); s.setString(2, source); s.setLong(3, lo); s.setLong(4, hi)
        if (old) { s.setLong(5, lo); s.setLong(6, hi); s.setLong(7, lo); s.setLong(8, hi) }
    }

    private fun differential(lo: Long = 100, hi: Long = 101, owner: UUID = u, source: String = device.toString(),
                             intended: IntendedPolicyDifference? = null): List<RrInterval> =
        pg.connection().use { c ->
            // The old query is deliberately restricted to tiny controls, never the dense fixture.
            c.createStatement().use { s ->
                s.execute("set statement_timeout='5s'")
                s.executeQuery("select count(*) from noop_rr_intervals").use { r ->
                    r.next(); check(r.getLong(1) <= 256) { "old RR query is forbidden on a dense fixture" }
                }
            }
            val old = c.prepareStatement(originalQuery).use { s ->
                bind(s, owner, source, lo, hi, true)
                s.executeQuery().use { r -> buildList {
                    while (r.next()) add(RrInterval(source, r.getLong("ts"), r.getInt("rrMs"), r.getInt("seq"),
                        ord = r.getObject("ord") as? Int, srcChannel = r.getObject("srcChannel") as? Int,
                        tsSuspect = r.getObject("tsSuspect") as? Int))
                } }
            }
            val actual = SignalSampleReader(pg.db).loadRr(c, owner, source, lo, hi)
            val expected = if (intended == null) old else {
                assertTrue("intentional policy difference must not disguise equality", intended.historical != intended.current)
                assertEquals("frozen historical query's complete ordered rows", intended.historical, old)
                assertEquals("only stored-code 2 removal and unmapped 110 admission may differ",
                    old.filter { it.srcChannel != 2 }, actual.filter { it.srcChannel != 110 })
                intended.current
            }
            assertEquals("complete ordered RR rows", expected, actual)
            assertEquals("row multiplicity", expected.groupingBy { it }.eachCount(), actual.groupingBy { it }.eachCount())
            actual
        }

    @Test fun allModernAliasesRetainCanonicalPriorityAndCompleteRows() {
        insert(Beat(channel = 5, ord = 2, suspect = 0), Beat(rr = 810, channel = 5, ord = 1),
            Beat(rr = 820, channel = 7), Beat(rr = 830, channel = 6), Beat(rr = 840),
            Beat(rr = 850, channel = 110), Beat(rr = 860, channel = 5, suspect = 1))
        for (name in listOf("whoop5", "whoop5_mg", "whoopmg", "whoop 5.0", "5.0", "mg", "WhOoP5")) {
            family(name)
            assertEquals(name, listOf(810, 800), differential().map { it.rrMs })
        }
    }

    @Test fun onlyNullFamilyInfersModernAndExplicitLegacyUnknownOrWhitespaceNeverDo() {
        insert(Beat(), Beat(rr = 810, channel = 5), Beat(rr = 820, channel = 7),
            Beat(rr = 830, channel = 6), Beat(rr = 840, channel = 2))
        for (name in listOf("whoop4", "", "unknown", " whoop5 ")) {
            family(name)
            val expected = expectedRows(Beat(), Beat(rr = 810, channel = 5), Beat(rr = 820, channel = 7),
                Beat(rr = 830, channel = 6))
            val historical = expected + expectedRows(Beat(rr = 840, channel = 2))
            assertEquals(name, listOf(800, 810, 820, 830),
                differential(intended = IntendedPolicyDifference(historical, expected)).map { it.rrMs })
        }
        family(null)
        assertEquals(listOf(810), differential().map { it.rrMs })
    }

    @Test fun channelSevenFallbackAndSixOnlyDoNotManufactureCanonicalBeats() {
        for (name in listOf("whoop5", null)) {
            family(name)
            sql("delete from noop_rr_intervals")
            insert(Beat(), Beat(rr = 810, channel = 6), Beat(rr = 820, channel = 7),
                Beat(rr = 830, channel = 5, suspect = 1), Beat(ts = 102, channel = 5))
            assertEquals(listOf(820), differential().map { it.rrMs })
            sql("delete from noop_rr_intervals where \"srcChannel\"=7")
            assertTrue("6 evidence without 5/7 selects nothing ($name)", differential().isEmpty())
        }
        family("whoop4")
        assertEquals(listOf(800, 810), differential().map { it.rrMs })
    }

    @Test fun nullSourcesStoredIbiSuspectOnlyAndEmptyWindowsHaveExplicitPolicyDelta() {
        for (name in listOf("whoop5", "whoop4", null)) {
            family(name)
            sql("delete from noop_rr_intervals")
            assertTrue(differential().isEmpty())
            insert(Beat(rr = 810, channel = 2), Beat(rr = 820, channel = 5, suspect = 1))
            val excludedIbi = expectedRows(Beat(rr = 810, channel = 2))
            val beforeNull = if (name == "whoop5") null else IntendedPolicyDifference(excludedIbi, emptyList())
            assertTrue(differential(intended = beforeNull).isEmpty())
            insert(Beat())
            val afterNull = if (name == "whoop5") null else
                IntendedPolicyDifference(expectedRows(Beat()) + excludedIbi, expectedRows(Beat()))
            assertEquals(if (name == "whoop5") emptyList<Int>() else listOf(800),
                differential(intended = afterNull).map { it.rrMs })
        }
    }

    @Test fun storedSpo2CodeIsExcludedWithoutDeletingRawOrReorderingOtherLegacyChannels() {
        assertEquals("durable enum code, not Oura wire tag 0x6E", 2, RrSourceChannel.SPO2_IBI.code)
        val nullSource = Beat(rr = 900, seq = 2)
        val green = Beat(rr = 900, seq = 3, channel = 1)
        val amplitude = Beat(rr = 850, seq = 1, ord = 0, channel = 3)
        val bare = Beat(rr = 840, ord = 1, channel = 4)
        val spo2 = Beat(rr = 910, channel = RrSourceChannel.SPO2_IBI.code)
        val suspect = Beat(rr = 870, ord = 0, channel = 1, suspect = 1)
        insert(bare, spo2, green, suspect, amplitude, nullSource)
        val historical = expectedRows(nullSource, green, spo2, amplitude, bare)
        val expected = expectedRows(nullSource, green, amplitude, bare)
        for (name in listOf("whoop4", null, "unknown", "")) {
            family(name)
            val actual = differential(intended = IntendedPolicyDifference(historical, expected))
            assertEquals(listOf(null, 1, 3, 4), actual.map { it.srcChannel })
            assertEquals(listOf(2, 3, 1, 0), actual.map { it.seq })
            assertEquals(listOf(null, null, 0, 1), actual.map { it.ord })
        }
        assertEquals("all raw measurements retained", "6", scalar("select count(*) from noop_rr_intervals"))
        assertEquals("excluded stored-code row retained unchanged", "1", scalar("""select count(*) from noop_rr_intervals
            where user_id='$u' and device_id='$device' and ts=100 and "rrMs"=910 and seq=0
              and ord is null and "srcChannel"=2 and "tsSuspect" is null"""))
    }

    @Test fun wireTag110IsNotSilentlyAliasedToStoredSpo2Code() {
        val unlabelled = Beat()
        val wireTag = Beat(rr = 810, channel = 110)
        insert(wireTag, unlabelled)
        for (name in listOf("whoop4", null, "unknown", "")) {
            family(name)
            val actual = differential(intended = IntendedPolicyDifference(
                expectedRows(unlabelled), expectedRows(unlabelled, wireTag)))
            assertEquals(listOf(null, 110), actual.map { it.srcChannel })
        }
        family("whoop5")
        assertTrue("an unknown wire tag is not canonical WHOOP5 evidence", differential().isEmpty())
        assertEquals("2", scalar("select count(*) from noop_rr_intervals"))
    }

    @Test fun canonicalFiveAndSevenStillExcludeStoredIbiAndUnmappedWireTag() {
        for (name in listOf("whoop5", null)) {
            family(name)
            sql("delete from noop_rr_intervals")
            insert(Beat(channel = 2), Beat(rr = 810, channel = 110), Beat(rr = 820),
                Beat(rr = 830, channel = 6), Beat(rr = 840, channel = 7),
                Beat(rr = 850, channel = 5, suspect = 1), Beat(ts = 102, channel = 5))
            assertEquals(expectedRows(Beat(rr = 840, channel = 7)), differential())
            insert(Beat(rr = 860, channel = 5))
            assertEquals(expectedRows(Beat(rr = 860, channel = 5)), differential())
            sql("delete from noop_rr_intervals where \"srcChannel\" in (5,7)")
            assertTrue("6-only modern evidence still selects no RR", differential().isEmpty())
        }
    }

    @Test fun suspectExactlyOneIsRejectedWithoutAddingPhysiologicalFilters() {
        insert(Beat(channel = 5, suspect = null), Beat(rr = 810, channel = 5, suspect = 0),
            Beat(rr = 820, channel = 5, suspect = 1), Beat(rr = 830, channel = 5, suspect = 2),
            Beat(rr = 840, channel = 5, suspect = -1), Beat(rr = -10, channel = 5))
        assertEquals(listOf(-10, 800, 810, 830, 840), differential().map { it.rrMs })
        assertEquals(listOf(null, null, 0, 2, -1), differential().map { it.tsSuspect })
    }

    @Test fun ownerDeviceAndBothInclusiveBoundsAlsoScopeFamilyEvidence() {
        family(null)
        insert(Beat(), Beat(ts = 101, rr = 801), Beat(ts = 99, channel = 5), Beat(ts = 102, channel = 5),
            Beat(rr = 900, channel = 5, owner = other), Beat(rr = 910, channel = 5, sourceDevice = device2))
        assertEquals(listOf(100L, 101L), differential().map { it.ts })
        assertEquals(listOf(900), differential(owner = other).map { it.rrMs })
        assertEquals(listOf(910), differential(source = device2.toString()).map { it.rrMs })
        insert(Beat(ts = 100, rr = 820, channel = 7), Beat(ts = 101, rr = 821, channel = 7))
        assertEquals(listOf(820, 821), differential().map { it.rrMs })
        assertEquals(listOf(820), differential(100, 100).map { it.rrMs })
        assertEquals(listOf(821), differential(101, 101).map { it.rrMs })
        assertTrue(differential(101, 100).isEmpty())
    }

    @Test fun missingDeviceAndExactTextPredicatePreserveExistingPassThrough() {
        val missing = UUID.fromString("abcdefab-cdef-4abc-8def-abcdefabcdef")
        insert(Beat(sourceDevice = missing), Beat(rr = 810, channel = 5, sourceDevice = missing),
            Beat(rr = 820, channel = 6, sourceDevice = missing))
        assertEquals(listOf(800, 810, 820), differential(source = missing.toString()).map { it.rrMs })
        assertTrue(differential(source = missing.toString().uppercase()).isEmpty())
        assertTrue(differential(source = "not-a-uuid").isEmpty())
    }

    @Test fun sameSecondOrdNullAndNumericTiesKeepEverySeqInNativeOrder() {
        insert(Beat(rr = 950, seq = 9, ord = 0, channel = 5), Beat(rr = 910, seq = 4, ord = null, channel = 5),
            Beat(rr = 900, seq = 3, ord = null, channel = 5), Beat(rr = 900, seq = 2, ord = null, channel = 5),
            Beat(rr = 800, seq = 1, ord = 0, channel = 5), Beat(ts = 101, rr = 700, ord = -1, channel = 5))
        val rows = differential()
        assertEquals(listOf(2, 3, 4, 1, 9, 0), rows.map { it.seq })
        assertEquals(listOf(null, null, null, 0, 0, -1), rows.map { it.ord })
        assertEquals(listOf(900, 900, 910, 800, 950, 700), rows.map { it.rrMs })
    }

    @Test fun denseNewQueryUsesOneWindowScanAndOnePolicyAggregateUnderTimeout() {
        pg.connection().use { c ->
            c.autoCommit = false
            try {
                c.createStatement().use { s ->
                    s.execute("set local statement_timeout='30s'")
                    s.executeUpdate("""insert into noop_rr_intervals
                        (user_id,device_id,source_id,ts,"rrMs",seq,ord,"srcChannel","tsSuspect",batch_id)
                        select '$u','$device','$u',100+g,800+g%3,g%2,
                            case when g%5=0 then null else g%3 end,5,null,'$u'
                        from generate_series(0,28799) g""")
                    s.execute("set local statement_timeout='10s'")
                }
                var preparedSql: String? = null
                val capturing = Proxy.newProxyInstance(Connection::class.java.classLoader, arrayOf(Connection::class.java)) { _, method, args ->
                    if (method.name == "prepareStatement") {
                        check(preparedSql == null) { "loadRr must issue one statement" }
                        preparedSql = args!![0] as String
                    }
                    try { method.invoke(c, *(args ?: emptyArray())) }
                    catch (error: InvocationTargetException) { throw error.targetException }
                } as Connection
                val started = System.nanoTime()
                val rows = SignalSampleReader(pg.db).loadRr(capturing, u, device.toString(), 100, 28_899)
                val elapsedMs = (System.nanoTime() - started) / 1_000_000.0
                assertEquals(28_800, rows.size)
                rows.forEachIndexed { index, r ->
                    assertEquals(RrInterval(device.toString(), 100L + index, 800 + index % 3, index % 2,
                        ord = if (index % 5 == 0) null else index % 3, srcChannel = 5), r)
                }
                // Capture the exact production-prepared SQL, not a separately maintained candidate.
                val planText = c.prepareStatement("EXPLAIN (ANALYZE, BUFFERS, VERBOSE, FORMAT JSON) ${requireNotNull(preparedSql)}").use { s ->
                    bind(s, u, device.toString(), 100, 28_899, false)
                    s.executeQuery().use { r -> check(r.next()); r.getString(1) }
                }
                Files.writeString(pg.directory.resolve("canonical-rr-dense-new-plan.json"), planText)
                val explain = JSONArray(planText).getJSONObject(0)
                val nodes = mutableListOf<JSONObject>()
                fun visit(n: JSONObject) {
                    nodes.add(n)
                    val children = n.optJSONArray("Plans") ?: return
                    for (index in 0 until children.length()) visit(children.getJSONObject(index))
                }
                visit(explain.getJSONObject("Plan"))
                val scans = nodes.filter { it.optString("Relation Name") == "noop_rr_intervals" }
                assertEquals("one base RR scan", 1, scans.size)
                assertEquals("base RR scan runs once", 1, scans.single().getInt("Actual Loops"))
                assertEquals(28_800, scans.single().getInt("Actual Rows"))
                for (name in listOf("CTE rr_window", "CTE rr_policy", "CTE decision")) {
                    val node = nodes.single { it.optString("Subplan Name") == name }
                    assertEquals(name, 1, node.getInt("Actual Loops"))
                    if (name != "CTE rr_window") assertEquals(name, 1, node.getInt("Actual Rows"))
                }
                assertEquals("one policy aggregate", 1, nodes.count { it.getString("Node Type") == "Aggregate" })
                println("RR_DENSE_NEW rows=${rows.size} jdbcMs=$elapsedMs executionMs=${explain.getDouble("Execution Time")} plan=${pg.directory.resolve("canonical-rr-dense-new-plan.json")}")
            } finally { c.rollback() }
        }
    }

    // Frozen pre-repair SQL, used ONLY by <=256-row differential controls above.
    private val originalQuery = """
        select ts, "rrMs", seq, ord, "srcChannel", "tsSuspect"
        from public.noop_rr_intervals r
        where user_id = ? and device_id::text = ? and ts between ? and ?
          and ("tsSuspect" is null or "tsSuspect" <> 1)
          and ("srcChannel" is null or "srcChannel" <> 110)
          and (not exists(select 1 from public.devices d where d.id=r.device_id and
                 (lower(coalesce(d.device_family,'')) in ('whoop5','whoop5_mg','whoopmg','whoop 5.0','5.0','mg')
                   or (d.device_family is null and exists(select 1 from public.noop_rr_intervals e
                     where e.user_id=r.user_id and e.device_id=r.device_id and e.ts between ? and ?
                       and e."srcChannel" in (5,6,7) and (e."tsSuspect" is null or e."tsSuspect"<>1)))))
               or "srcChannel"=(select min(q."srcChannel") from public.noop_rr_intervals q
                 where q.user_id=r.user_id and q.device_id=r.device_id and q.ts between ? and ?
                   and q."srcChannel" in (5,7) and (q."tsSuspect" is null or q."tsSuspect"<>1)))
        order by ts asc, ord asc nulls first, "rrMs" asc, seq asc
    """.trimIndent()
}
