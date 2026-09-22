package com.frwhoop.scoring

import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import java.sql.Connection
import java.sql.SQLException
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class HistoryInputRpcIntegrationTest : PgIntegrationBase() {
    private val client = UUID.fromString("30000000-0000-4000-8000-000000000001")
    private fun profile(age: Int = 30, timezone: String = "UTC") = JSONObject()
        .put("schemaVersion", 1).put("age", age).put("timezone", timezone)

    private fun asUser(c: Connection, owner: UUID = u) {
        c.createStatement().use {
            it.execute("set role authenticated")
            it.execute("set request.jwt.claim.sub='$owner'")
        }
    }

    private fun put(c: Connection, body: JSONObject = profile(), effective: String = day,
                    expected: Long = 0, mutation: UUID = UUID.randomUUID(), clientRevision: Long = expected + 1,
                    deleted: Boolean = false, kind: String = "profile", entity: String = "primary",
                    clientId: UUID = client): JSONObject =
        c.prepareStatement("select put_scoring_history_input_v3(?,?,?,?::date,?::jsonb,?,?,?,?,?)::text").use { s ->
            s.setObject(1, device); s.setString(2, kind); s.setString(3, entity); s.setString(4, effective)
            s.setString(5, body.toString()); s.setLong(6, expected); s.setBoolean(7, deleted)
            s.setObject(8, clientId); s.setObject(9, mutation); s.setLong(10, clientRevision)
            s.executeQuery().use { r -> r.next(); JSONObject(r.getString(1)) }
        }

    private fun read(c: Connection, asOf: String, kind: String = "profile", entity: String = "primary") =
        c.prepareStatement("select get_scoring_history_input_v3(?,?,?,?::date)::text").use { s ->
            s.setObject(1, device); s.setString(2, kind); s.setString(3, entity); s.setString(4, asOf)
            s.executeQuery().use { r -> r.next(); JSONObject(r.getString(1)) }
        }

    private fun head(c: Connection, kind: String = "profile", entity: String = "primary") =
        c.prepareStatement("select get_scoring_history_input_head_v3(?,?,?)::text").use { s ->
            s.setObject(1, device); s.setString(2, kind); s.setString(3, entity)
            s.executeQuery().use { r -> r.next(); JSONObject(r.getString(1)) }
        }

    private fun sqlState(code: String, call: () -> Unit) {
        val error = assertThrows(SQLException::class.java) { call() }
        assertEquals(code, error.sqlState)
    }

    @Test fun exactRetryIsDurableAndAddsNeitherRevisionNorInvalidation() {
        val mutation = UUID.randomUUID()
        pg.connection().use { c ->
            asUser(c)
            val first = put(c, mutation = mutation)
            val debt = scalar("select count(*) from scoring_invalidations_v2")
            val retry = put(c, mutation = mutation)
            assertTrue(first.similar(retry))
            assertEquals(u.toString(), first.getString("userId"))
            assertEquals(device.toString(), first.getString("sourceDeviceId"))
            assertEquals("1", scalar("select count(*) from scoring_history_inputs_v3"))
            assertEquals(debt, scalar("select count(*) from scoring_invalidations_v2"))
            sqlState("23505") { put(c, profile(31), mutation = mutation) }
        }
    }

    @Test fun wrongOwnerAndDirectTableWritesAreRejected() {
        pg.connection().use { c ->
            asUser(c, other)
            sqlState("42501") { put(c) }
            sqlState("42501") { read(c, day) }
            sqlState("42501") { head(c) }
            c.createStatement().use { s -> sqlState("42501") { s.execute("delete from scoring_history_inputs_v3") } }
        }
        assertEquals("0", scalar("select count(*) from scoring_history_inputs_v3"))
    }

    @Test fun optimisticAndClientRevisionsCannotSilentlyOverwrite() {
        pg.connection().use { c ->
            asUser(c)
            val first = put(c).getLong("revision")
            sqlState("40001") { put(c, profile(31)) }
            sqlState("40001") { put(c, profile(31), expected = first, clientRevision = 1) }
            val second = put(c, profile(31), expected = first, clientRevision = 2)
            assertTrue(second.getLong("revision") > first)
            assertEquals(31, read(c, day).getJSONObject("payload").getInt("age"))
        }
    }

    @Test fun revisionsAreOpaqueAndPerEntityExpectedHeadsMaySkipSequenceValues() {
        pg.connection().use { c ->
            asUser(c)
            val first = put(c, clientRevision = 1).getLong("revision")
            val config = put(c, JSONObject().put("schemaVersion", 1), kind = "config", clientRevision = 1)
            assertTrue(config.getLong("revision") > first)
            val mutation = UUID.randomUUID()
            val next = put(c, profile(31), expected = first, clientRevision = 2, mutation = mutation)
            assertTrue(next.getLong("revision") > first + 1)
            assertEquals("primary", next.getString("entity"))
            assertEquals(client.toString(), next.getString("clientId"))
            assertEquals(mutation.toString(), next.getString("clientMutationId"))
            assertEquals(2L, next.getLong("clientRevision"))
            put(c, profile(32), expected = next.getLong("revision"), clientRevision = 3)
            // Even after a later edit, a lost-ACK retry returns THAT request's original receipt.
            assertTrue(next.similar(put(c, profile(31), expected = first, clientRevision = 2, mutation = mutation)))
        }
    }

    @Test fun freshInstallationMustReadHeadAndExplicitlyRebaseWithNewMutation() {
        pg.connection().use { c ->
            asUser(c)
            val existing = put(c).getLong("revision")
            val fresh = UUID.randomUUID()
            sqlState("40001") { put(c, profile(31), clientId = fresh, clientRevision = 1) }
            assertEquals(existing, head(c).getLong("headRevision"))
            val remote = read(c, day)
            assertEquals(existing, remote.getLong("headRevision"))
            assertEquals(30, remote.getJSONObject("payload").getInt("age"))
            val rebased = put(c, profile(31), clientId = fresh, clientRevision = 2, expected = existing)
            assertTrue(rebased.getLong("revision") > existing)
            sqlState("22023") { put(c, entity = "default") }
            sqlState("22023") { read(c, day, entity = "default") }
            sqlState("22023") { head(c, entity = "default") }
        }
    }

    @Test fun headRpcReturnsOnlyOwnedMetadataEvenForFuturePayloadAndAbsentEntity() {
        pg.connection().use { c ->
            asUser(c)
            assertEquals(0L, head(c).getLong("headRevision"))
            val future = put(c, profile(60, "Pacific/Auckland"), effective = "2026-10-01")
            val metadata = head(c)
            assertEquals(setOf("schemaVersion","userId","sourceDeviceId","kind","entity","headRevision"),metadata.keySet())
            assertEquals(future.getLong("revision"), metadata.getLong("headRevision"))
            assertEquals(u.toString(), metadata.getString("userId"))
            assertEquals(device.toString(), metadata.getString("sourceDeviceId"))
            assertTrue(read(c, day).isNull("payload"))
            assertEquals(0L, head(c, "config").getLong("headRevision"))
            sqlState("22023") { head(c, "unknown") }
            c.createStatement().use { it.execute("set request.jwt.claim.sub='' ") }
            sqlState("42501") { head(c) }
        }
    }

    @Test fun earlierWakeDayCorrectionReplacesOlderEditOnLaterDaysWithoutFutureLeakage() {
        val original = JSONObject().put("schemaVersion",1).put("originalStart",1789440000L)
            .put("originalEnd",1789470000L).put("start",1789441000L).put("end",1789470000L)
            .put("isNap",false).put("dismissed",false)
        val entity = "sleep:40000000-0000-4000-8000-000000000001"
        pg.connection().use { c ->
            asUser(c)
            val first = put(c, original, kind="sleep_edit", entity=entity).getLong("revision")
            val earlier = JSONObject(original.toString()).put("start",1789441000L-86400).put("end",1789470000L-86400)
            val corrected = put(c,earlier,effective="2026-09-14",expected=first,kind="sleep_edit",entity=entity)
            assertTrue(read(c,"2026-09-14","sleep_edit",entity).getJSONObject("payload").similar(earlier))
            assertTrue(read(c,day,"sleep_edit",entity).getJSONObject("payload").similar(earlier))
            assertTrue(read(c,"2026-09-13","sleep_edit",entity).isNull("payload"))
            put(c,original,effective="2026-09-17",expected=corrected.getLong("revision"),kind="sleep_edit",entity=entity)
            assertTrue(read(c,day,"sleep_edit",entity).getJSONObject("payload").similar(earlier))
            assertTrue(read(c,"2026-09-17","sleep_edit",entity).getJSONObject("payload").similar(original))
        }
    }

    @Test fun asOfSelectionNeverUsesFutureProfileAndPastCorrectionKeepsLaterVersion() {
        pg.connection().use { c ->
            asUser(c)
            val first = put(c, profile(30), effective = "2026-09-01").getLong("revision")
            val future = put(c, profile(60, "Pacific/Auckland"), effective = "2026-10-01", expected = first).getLong("revision")
            assertEquals(30, read(c, day).getJSONObject("payload").getInt("age"))
            assertEquals("UTC", read(c, day).getJSONObject("payload").getString("timezone"))
            assertEquals(future, read(c, day).getLong("headRevision"))
            put(c, profile(31), effective = "2026-09-01", expected = future)
            assertEquals(31, read(c, day).getJSONObject("payload").getInt("age"))
            assertEquals(60, read(c, "2026-10-02").getJSONObject("payload").getInt("age"))
            assertTrue(read(c, "2026-08-31").isNull("payload"))
        }
    }

    @Test fun sleepTombstoneIsVersionedAndCannotReassignOriginalIdentityOnRevival() {
        val entity = "sleep:40000000-0000-4000-8000-000000000001"
        val edit = JSONObject().put("schemaVersion", 1).put("originalStart", 1789440000)
            .put("originalEnd", 1789470000).put("start", 1789441000).put("end", 1789470000)
            .put("isNap", false).put("dismissed", false)
        pg.connection().use { c ->
            asUser(c)
            val first = put(c, edit, kind = "sleep_edit", entity = entity).getLong("revision")
            val tombstone = put(c, JSONObject(), expected = first, deleted = true, effective = "2026-09-16",
                kind = "sleep_edit", entity = entity).getLong("revision")
            assertFalse(read(c, day, "sleep_edit", entity).getBoolean("deleted"))
            assertTrue(read(c, "2026-09-16", "sleep_edit", entity).getBoolean("deleted"))
            assertTrue(read(c, "2026-09-16", "sleep_edit", entity).isNull("payload"))
            sqlState("22023") { put(c, JSONObject(edit.toString()).put("originalStart", 1789440100),
                expected = tombstone, kind = "sleep_edit", entity = entity) }
            put(c, edit, expected = tombstone, effective = "2026-09-16", kind = "sleep_edit", entity = entity)
            assertFalse(read(c, "2026-09-16", "sleep_edit", entity).getBoolean("deleted"))
        }
    }

    @Test fun timezoneUnknownFieldsAndNullSleepBoundsFailValidation() {
        pg.connection().use { c ->
            asUser(c)
            sqlState("22023") { put(c, profile(timezone = "not/a/timezone")) }
            sqlState("22023") { put(c, profile().put("user_id", other.toString())) }
            sqlState("22023") { put(c, profile().put("age", -5)) }
            sqlState("22023") { put(c, profile(), deleted = true) }
            val edit = JSONObject().put("schemaVersion", 1).put("originalStart", 1789440000)
                .put("originalEnd", 1789470000).put("start", JSONObject.NULL).put("end", 1789470000)
                .put("isNap", false).put("dismissed", false)
            sqlState("22023") { put(c, edit, kind = "sleep_edit", entity = "test") }
        }
        assertEquals("0", scalar("select count(*) from scoring_history_inputs_v3"))
        assertEquals("0", scalar("select count(*) from scoring_invalidations_v2"))
    }

    @Test fun authenticatedSleepStageNullMembersAndWrongTypesNeverCreateInputOrInvalidation() {
        val start=1789440000L
        val edit=JSONObject().put("schemaVersion",1).put("originalStart",start).put("originalEnd",start+3600)
            .put("start",start).put("end",start+3600).put("isNap",false).put("dismissed",false)
        fun stage()=JSONObject().put("start",start).put("end",start+3600).put("stage","light")
        val invalid=mutableListOf<Any>(JSONObject().put("start",JSONObject.NULL).put("end",JSONObject.NULL).put("stage",JSONObject.NULL),
            JSONObject.NULL,JSONArray(),"light",true,0)
        for(key in listOf("start","end","stage")) {
            invalid+=stage().put(key,JSONObject.NULL)
            invalid+=stage().apply { remove(key) }
        }
        for(key in listOf("start","end")) for(value in listOf<Any>("$start",true,JSONArray(),JSONObject(),start+0.5))
            invalid+=stage().put(key,value)
        for(value in listOf<Any>(0,false,JSONArray(),JSONObject(),"unknown")) invalid+=stage().put("stage",value)
        invalid+=stage().put("unexpected",0)
        invalid+=stage().put("start",start-1)
        invalid+=stage().put("end",start)
        invalid+=stage().put("end",start+3601)
        pg.connection().use { c ->
            asUser(c)
            for(value in invalid) sqlState("22023") {
                put(c,JSONObject(edit.toString()).put("stages",JSONArray().put(value)),kind="sleep_edit",
                    entity="sleep:40000000-0000-4000-8000-000000000001")
            }
            val overlaps=JSONArray().put(stage().put("end",start+1200)).put(stage().put("start",start+1100))
            sqlState("22023") { put(c,JSONObject(edit.toString()).put("stages",overlaps),kind="sleep_edit",
                entity="sleep:40000000-0000-4000-8000-000000000001") }
        }
        assertEquals("0",scalar("select count(*) from scoring_history_inputs_v3"))
        assertEquals("0",scalar("select count(*) from scoring_invalidations_v2"))
    }

    @Test fun authenticatedCanonicalSleepStagesAndZeroConfigurationRemainValid() {
        val start=1789440000L
        val stages=JSONArray()
        listOf("wake","light","deep","rem").forEachIndexed { index,stage ->
            stages.put(JSONObject().put("start",start+index*900).put("end",start+(index+1)*900).put("stage",stage))
        }
        val edit=JSONObject().put("schemaVersion",1).put("originalStart",start).put("originalEnd",start+3600)
            .put("start",start).put("end",start+3600).put("isNap",false).put("dismissed",false).put("stages",stages)
        val entity="sleep:40000000-0000-4000-8000-000000000001"
        pg.connection().use { c ->
            asUser(c)
            val first=put(c,edit,kind="sleep_edit",entity=entity).getLong("revision")
            assertTrue(read(c,day,"sleep_edit",entity).getJSONObject("payload").similar(edit))
            val empty=JSONObject(edit.toString()).put("stages",JSONArray())
            put(c,empty,kind="sleep_edit",entity=entity,expected=first,clientRevision=2)
            assertEquals(0,read(c,day,"sleep_edit",entity).getJSONObject("payload").getJSONArray("stages").length())
            put(c,JSONObject().put("schemaVersion",1).put("stepsManualCoefficient",0),kind="config")
            assertEquals(0,read(c,day,"config").getJSONObject("payload").getInt("stepsManualCoefficient"))
        }
    }

    @Test fun twoClientsWithSameExpectedRevisionSerializeAndOnlyOneCommits() {
        val executor = Executors.newSingleThreadExecutor()
        try {
            pg.connection().use { first ->
                asUser(first); first.autoCommit = false
                put(first)
                val second = executor.submit<String?> {
                    pg.connection().use { c ->
                        asUser(c)
                        try { put(c, profile(31)); null } catch (e: SQLException) { e.sqlState }
                    }
                }
                try {
                    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
                    while (!second.isDone && scalar("select count(*) from pg_locks where not granted") == "0"
                        && System.nanoTime() < deadline) Thread.sleep(10)
                    assertFalse(second.isDone)
                } finally { first.commit() }
                assertEquals("40001", second.get(5, TimeUnit.SECONDS))
            }
        } finally { executor.shutdownNow() }
        assertEquals("1", scalar("select count(*) from scoring_history_inputs_v3"))
    }
}
