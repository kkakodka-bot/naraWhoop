package com.frwhoop.scoring

import com.frwhoop.scoring.db.EngineIngestWriter
import com.frwhoop.scoring.db.HistoryCheckpointReader
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.db.SignalSampleReader
import com.frwhoop.scoring.scoring.ContextMetricOrchestrator
import com.frwhoop.scoring.scoring.DayScorer
import com.frwhoop.scoring.scoring.HistoricalContextInputFactory
import com.frwhoop.scoring.scoring.HistoricalStateMachine
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.UUID

/** Synthetic raw observations, authenticated inputs and real ordered publication, not a hand-built result. */
class PopulatedContextSnapshotFixtureIntegrationTest : PgIntegrationBase() {
    private val count = 64
    private val finalDay = LocalDate.parse(day)
    private val firstDay = finalDay.minusDays((count - 1).toLong())
    private val filename = "W4-POPULATED-CONTEXT-SNAPSHOT-V2-NATIVE-FIXTURE.json"
    private val flagNames = listOf("alcohol", "stress", "sauna", "hardOrLateWorkout", "travelPhaseJump", "alreadyUnwell")

    private fun put(kind: String, entity: String, effective: LocalDate, body: JSONObject): Long =
        pg.connection().use { connection ->
            connection.createStatement().use {
                it.execute("set role authenticated")
                it.execute("set request.jwt.claim.sub='$u'")
            }
            connection.prepareStatement("select put_scoring_history_input_v3(?,?,?,?::date,?::jsonb,0,false,?,?,1)::text").use { statement ->
                statement.setObject(1, device)
                statement.setString(2, kind)
                statement.setString(3, entity)
                statement.setString(4, effective.toString())
                statement.setString(5, body.toString())
                statement.setObject(6, UUID.randomUUID())
                statement.setObject(7, UUID.randomUUID())
                statement.executeQuery().use { rows ->
                    assertTrue(rows.next())
                    JSONObject(rows.getString(1)).getLong("revision")
                }
            }
        }

    private fun consent(purpose: String) = JSONObject().put("purpose", purpose).put("policyVersion", 1)
        .put("decisionId", "50000000-0000-4000-8000-000000000001")

    private fun seedRawObservations() {
        val first = firstDay.atStartOfDay(ZoneOffset.UTC).toEpochSecond()
        // HR also supplies exact-second worn evidence for every thermal sample. Last two nights
        // contain an observed HR rise and RR-variability fall; no derived row is inserted.
        sql("""
            insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
            select '$u','$device',gen_random_uuid(),$first+d*86400+n,
              round(70+14*cos(2*pi()*(n/3600.0-15)/24)+case when d>=${count - 2} then 8 else 0 end)::integer,
              gen_random_uuid()
            from generate_series(0,${count - 1}) d cross join generate_series(0,86370,30) n
        """.trimIndent())
        // Same synthetic RSA construction as RespRateRsaTest: beat timestamps advance by RR,
        // not a five-second sampling grid. Missing the rest of the night remains missing.
        pg.connection().use { connection ->
            connection.prepareStatement("""
                insert into noop_rr_intervals(user_id,device_id,source_id,ts,"rrMs",seq,ord,"srcChannel","tsSuspect",batch_id)
                select ?,?,gen_random_uuid(),r.ts,r.rr,(r.ordinality-1)::integer,0,5,0,gen_random_uuid()
                from unnest(?::bigint[],?::integer[]) with ordinality as r(ts,rr,ordinality)
            """.trimIndent()).use { statement ->
                repeat(count) { index ->
                    var elapsed = 0.0
                    val timestamps = ArrayList<Long>(5040)
                    val intervals = ArrayList<Int>(5040)
                    val amplitude = if (index >= count - 2) 8.0 else 60.0
                    repeat(5040) {
                        val rr = (1000.0 + amplitude * kotlin.math.sin(2 * Math.PI * 0.25 * elapsed)).toInt()
                        elapsed += rr / 1000.0
                        timestamps += first + index * 86400L + elapsed.toLong()
                        intervals += rr
                    }
                    val timesArray = connection.createArrayOf("bigint", timestamps.toTypedArray())
                    val intervalsArray = connection.createArrayOf("integer", intervals.toTypedArray())
                    try {
                        statement.setObject(1, u)
                        statement.setObject(2, device)
                        statement.setArray(3, timesArray)
                        statement.setArray(4, intervalsArray)
                        statement.executeUpdate()
                    } finally {
                        timesArray.free()
                        intervalsArray.free()
                    }
                }
            }
        }
        sql("""
            insert into noop_skin_temp_samples(user_id,device_id,source_id,ts,raw,batch_id)
            select '$u','$device',gen_random_uuid(),$first+d*86400+n,
              round(3400+50*sin(2*pi()*d/28))::integer,gen_random_uuid()
            from generate_series(0,${count - 1}) d cross join generate_series(0,25170,30) n
        """.trimIndent())
        assertEquals((count * 2880).toString(), scalar("select count(*) from noop_hr_samples where user_id='$u' and device_id='$device'"))
        assertEquals((count * 5040).toString(), scalar("select count(*) from noop_rr_intervals where user_id='$u' and device_id='$device'"))
        assertEquals((count * 840).toString(), scalar("select count(*) from noop_skin_temp_samples where user_id='$u' and device_id='$device'"))
    }

    private fun seedInputs(): Pair<Long, Long> {
        val profile = put("profile", "primary", firstDay, JSONObject().put("schemaVersion", 1)
            .put("age", 40).put("sex", "female").put("weightKg", 65).put("heightCm", 170).put("timezone", "UTC"))
        val config = put("config", "primary", firstDay, JSONObject().put("schemaVersion", 1)
            .put("dayCycleMode", "midnight").put("useSleepStagerV2", true).put("deepHrvWindow", false)
            .put("journalContextEnabled", true).put("cycleAwarenessEnabled", true)
            .put("hrvBaselineEpoch", 0).put("recoveryBaselineEpoch", 0))
        repeat(count) { index ->
            val date = firstDay.plusDays(index.toLong())
            val start = date.atStartOfDay(ZoneOffset.UTC).toEpochSecond()
            val id = UUID.nameUUIDFromBytes("populated-context-sleep:$date".toByteArray(Charsets.UTF_8))
            put("sleep_edit", "sleep:$id", date, JSONObject().put("schemaVersion", 1)
                .put("originalStart", start).put("originalEnd", start + 7 * 3600)
                .put("start", start).put("end", start + 7 * 3600).put("isNap", false).put("dismissed", false))
        }
        for (index in listOf(0, 28, 56)) {
            val date = firstDay.plusDays(index.toLong())
            val id = UUID.nameUUIDFromBytes("populated-context-period:$date".toByteArray(Charsets.UTF_8))
            put("period", "period:$id", date, JSONObject().put("schemaVersion", 1).put("day", date.toString())
                .put("timezone", "UTC").put("event", "period_start").put("consent", consent("cycle_context")))
        }
        put("context", "context:$day", finalDay, JSONObject().put("schemaVersion", 1).put("day", day)
            .put("timezone", "UTC").put("consent", consent("journal_context"))
            .put("flags", JSONObject(flagNames.associateWith { false })))
        assertEquals("0", scalar("select count(*) from scoring_history_inputs_v3 where user_id='$u' and device_id='$device' and payload ? 'stages'"))
        return profile to config
    }

    private fun authenticatedRead(version: String): JSONObject = pg.connection().use { connection ->
        connection.createStatement().use {
            it.execute("set role authenticated")
            it.execute("set request.jwt.claim.sub='$u'")
        }
        connection.prepareStatement("select get_server_score_snapshot_v2(?::date,?)::text").use { statement ->
            statement.setString(1, day)
            statement.setString(2, version)
            statement.executeQuery().use { rows ->
                assertTrue(rows.next())
                JSONObject(rows.getString(1))
            }
        }
    }

    @Test fun populatedContextTravelsFromRawHistoryThroughFencedSnapshotAndAuthenticatedRead() {
        val directory = Path.of(requireNotNull(System.getenv("W3_TEST_ARTIFACTS")) {
            "Dedicated context fixture gate requires W3_TEST_ARTIFACTS; no skip or null-fixture fallback"
        })
        seedRawObservations()
        val (profileRevision, configurationRevision) = seedInputs()
        val queue = ScoringWorkQueue(pg.db, "frwhoop-server-2-history")
        queue.maintain(1000)
        repeat(count) { queue.dirtyWorkItem(u, device, firstDay.plusDays(it.toLong()).toString()) }
        var passes = 0
        do {
            assertTrue("bounded invalidation expansion", ++passes <= 64)
            queue.maintain(1000)
        } while (scalar("select count(*) from scoring_invalidations_v2") != "0")

        val reader = SignalSampleReader(pg.db)
        assertNull(reader.loadHistoricalDay(other, day, device))
        val checkpoints = HistoryCheckpointReader(pg.db)
        val writer = EngineIngestWriter(queue)
        var previousDay: String? = null
        var previousRevision: Long? = null
        val observedDays = mutableSetOf<String>()
        var targetRevision: Long? = null
        var targetContext: JSONObject? = null
        var claims = 0
        while (true) {
            val item = queue.claim() ?: break
            assertTrue("bounded ordered scoring", ++claims <= count + 16)
            assertEquals(u, item.userId)
            assertEquals(device, item.deviceId)
            assertTrue(previousDay == null || previousDay < item.day)
            assertEquals(previousRevision, item.predecessorRevision)
            val input = requireNotNull(reader.loadHistoricalDay(u, item.day, device))
            val seed = checkpoints.load(item)
            assertTrue(seed.history.all { it.getString("day") < item.day })
            val prepared = HistoricalStateMachine.prepare(input, seed)
            val bundle = DayScorer().score(input, queue.algorithmVersion, prepared)
            if (item.day in firstDay.toString()..day) {
                observedDays += item.day
                assertNotNull("earned RHR for ${item.day}", bundle.result.daily.restingHr)
                assertNotNull("earned HRV for ${item.day}", bundle.result.daily.avgHrv)
                assertNotNull("wear-gated temperature for ${item.day}", bundle.result.nightlySkinTempC)
            }
            if (item.day == day) {
                assertEquals(profileRevision, input.history.profile!!.revision)
                assertEquals(configurationRevision, input.history.config!!.revision)
                for (key in listOf("hrv", "resting_hr", "skin_temp")) {
                    assertTrue("earned trusted $key baseline", prepared.baselines.getValue(key).trusted)
                    assertTrue(prepared.baselines.getValue(key).nValid >= 14)
                }
                assertTrue(prepared.history.size >= count - 1)
                val context = HistoricalContextInputFactory.build(input, bundle.result, prepared, bundle.sleepNapOverrides)
                assertTrue(context.journalEnabled && context.cycleEnabled)
                assertTrue(flagNames.all { context.contextFlags[it] == false })
                assertEquals(3, context.periodStarts.size)
                val actual = ContextMetricOrchestrator.evaluate(context)
                targetContext = actual.details
                assertEquals("as-of-context-v1", actual.details.getString("contextPolicy"))
                assertNotEquals("learning", actual.details.getJSONObject("cycle").getString("phase"))
                assertNotEquals("unreadable", actual.details.getJSONObject("circadian").getString("confidence"))
                assertTrue(actual.details.getJSONObject("illness").getInt("signalCount") >= 2)
                // The kernel caller supplies no firedLabels. Do not invent labels from signalCount.
                assertEquals(0, actual.details.getJSONObject("illness").getJSONArray("firedSignals").length())
                val actualIllness = actual.details.getJSONObject("illness")
                assertTrue(actualIllness.getInt("distanceDeviatingFeatures") in 2..4)
                assertFalse(actualIllness.getBoolean("distanceUsedDiagonalFallback"))
                assertTrue(actualIllness.getBoolean("distanceFires"))
                assertFalse(actualIllness.getBoolean("distanceIsAlertGate"))
                assertTrue(actualIllness.getBoolean("wellnessOnly"))
                assertNull(writer.write(item.copy(leaseToken = UUID.randomUUID()), bundle, 1))
            }
            val revision = requireNotNull(writer.write(item, bundle, 1)) { "fenced publication rejected ${item.day}" }
            if (item.day == day) {
                targetRevision = revision
                assertNull("settled lease cannot publish twice", writer.write(item, bundle, 1))
            }
            previousDay = item.day
            previousRevision = revision
        }
        assertEquals((0 until count).map { firstDay.plusDays(it.toLong()).toString() }.toSet(), observedDays)
        val revision = requireNotNull(targetRevision) { "target day was not published" }
        val payload = JSONObject(requireNotNull(scalar("select payload::text from scoring_snapshots_v2 where result_revision=$revision and user_id='$u' and device_id='$device'")))
        assertEquals(2, payload.getInt("schemaVersion"))
        assertEquals(u.toString(), payload.getString("userId"))
        assertEquals(device.toString(), payload.getString("sourceDeviceId"))
        assertEquals(day, payload.getString("day"))
        assertEquals("UTC", payload.getString("timezone"))
        assertEquals(queue.algorithmVersion, payload.getString("algorithmVersion"))
        val dependency = payload.getJSONObject("dependency")
        assertEquals(profileRevision, dependency.getLong("profileRevision"))
        assertEquals(configurationRevision, dependency.getLong("configurationRevision"))
        assertTrue(dependency.getLong("predecessorResultRevision") > 0)
        assertEquals("1", scalar("select count(*) from scoring_history_checkpoints_v3 where result_revision=$revision and user_id='$u' and device_id='$device' and day='$day' and input_revision=${payload.getLong("inputRevision")} and generation=${dependency.getLong("generation")}"))
        val detail = payload.getJSONObject("details")
        for (family in listOf("illness", "cycle", "circadian"))
            assertTrue("unmodified actual $family result", requireNotNull(targetContext).getJSONObject(family).similar(detail.getJSONObject(family)))
        assertTrue(detail.getJSONObject("cycle").getString("note").isNotBlank())
        assertTrue(detail.getJSONObject("circadian").getString("note").isNotBlank())
        assertTrue(detail.getJSONObject("illness").getString("copy").isNotBlank())
        val distanceDetails = detail.getJSONObject("illness")
        assertTrue(distanceDetails.getInt("distanceDeviatingFeatures") in 2..4)
        assertFalse(distanceDetails.getBoolean("distanceUsedDiagonalFallback"))
        assertTrue(distanceDetails.getBoolean("distanceFires"))
        assertFalse(distanceDetails.getBoolean("distanceIsAlertGate"))
        assertTrue(distanceDetails.getBoolean("wellnessOnly"))
        assertEquals("IllnessDistance_identity_correlation",
            payload.getJSONObject("metrics").getJSONObject("illness_distance").getString("method"))
        val capabilities = payload.getJSONArray("capabilities").toList().toSet()
        for ((key, unit) in mapOf("illness_score" to "score_0_100", "illness_distance" to "dimensionless",
            "circadian_phase_hour" to "local_hour", "circadian_offset_min" to "min")) {
            assertTrue(key in capabilities)
            val metric = payload.getJSONObject("metrics").getJSONObject(key)
            assertEquals(unit, metric.getString("unit"))
            assertTrue(metric.getDouble("value").isFinite())
        }
        assertTrue("cycle_phase" in capabilities)
        assertTrue(payload.getJSONObject("charts").getJSONArray("cycle_index").length() >= 42)
        val sleep = payload.getJSONArray("sleep")
        assertTrue(sleep.length() > 0)
        assertTrue((0 until sleep.length()).any { sleep.getJSONObject(it).getJSONArray("stages").length() > 0 })
        assertTrue(payload.getJSONObject("coverage").getBoolean("historicalStateAvailable"))
        val gaps = payload.getJSONObject("coverage").getJSONArray("gaps").toList()
        for (gap in listOf("journal_context_not_shared", "journal_context_incomplete", "illness_baseline_learning",
            "cycle_context_not_shared", "cycle_history_learning", "cycle_temperature_baseline_unavailable",
            "circadian_hourly_history_unavailable", "circadian_rhythm_unreadable", "sleep_schedule_unavailable"))
            assertFalse("unexpected context gap: $gap", gap in gaps)

        val envelope = authenticatedRead(queue.algorithmVersion)
        assertEquals(revision, envelope.getLong("resultRevision"))
        assertFalse(envelope.getBoolean("pending"))
        for (mutable in listOf("requestedInputRevision", "pending", "archiveStatus")) {
            assertFalse("mutable field in immutable publication: $mutable", payload.has(mutable))
            envelope.remove(mutable)
        }
        assertTrue("authenticated read must return the same immutable publication", envelope.similar(payload))
        val bytes = payload.toString(2).toByteArray(Charsets.UTF_8)
        assertTrue("native readback response bound", bytes.size < 512 * 1024)
        val output = Files.createDirectories(directory).resolve(filename)
        Files.write(output, bytes)
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        println("W4 populated context fixture: $output SHA256=$digest bytes=${bytes.size} observedDays=${observedDays.size} claims=$claims")
    }
}
