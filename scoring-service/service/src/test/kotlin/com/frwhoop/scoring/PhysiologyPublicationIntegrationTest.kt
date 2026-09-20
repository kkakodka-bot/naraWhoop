package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.derived.DerivedArchiveOutbox
import com.frwhoop.scoring.derived.DerivedArtifactWriter
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.sql.SQLException
import java.util.UUID

/** Exercises publication and owner-scoped reads against the actual additive migrations. */
class PhysiologyPublicationIntegrationTest {
    private lateinit var db: PostgresClient
    private lateinit var queue: ScoringWorkQueue
    private val user = UUID.randomUUID()
    private val device = UUID.randomUUID()
    private val day = "2026-09-17"

    @Before fun setup() {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh", url != null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db = PostgresClient(url); queue = ScoringWorkQueue(db)
        sql("insert into auth.users values ('$user')")
        sql("insert into profiles(id,timezone) values ('$user','UTC')")
        sql("insert into devices(id,user_id) values ('$device','$user')")
    }
    @After fun close() { if (::db.isInitialized) {
        sql("update physiology_feature_qualifications set qualification='shadow',policy_sha256=null,evaluation_sha256=null," +
            "signed_policy=null,signed_evaluation=null,reviewed_by=null,reviewed_at=null where algorithm_version='frwhoop-physiology-2'")
        db.close()
    } }

    @Test fun publicationIsImmutableAndReplacesTheWholeGeneratedEpisodeSet() {
        val first = claim()
        publish(payload(first, 2))
        publish(payload(first, 2))
        assertEquals(1L, count("server_physiology_results"))
        assertEquals(1L, count("physiology_archive_outbox"))
        assertTrue(queue.markDone(first, 1))
        val next = claim()
        publish(payload(next, 1))
        assertEquals(2L, count("server_physiology_results"))
        assertEquals(1L, number("select jsonb_array_length(payload->'nights') from server_physiology_results " +
            "where user_id='$user' order by input_revision desc limit 1"))
        assertEquals(2L, number("select count(distinct object_key) from physiology_archive_outbox where user_id='$user'"))
    }

    @Test fun lateInputRejectsOldPublicationWithoutCreatingRowsOrArchiveWork() {
        val old = claim(); val latest = claim()
        expectFailure("40001") { publish(payload(old)) }
        assertEquals(0L, count("server_physiology_results"))
        assertEquals(0L, count("physiology_archive_outbox"))
        publish(payload(latest))
        expectFailure("40001") { publish(payload(old)) }
        assertEquals(latest.inputRevision, number("select input_revision from server_physiology_results where user_id='$user'"))
    }

    @Test fun deviceSnapshotsAndManualTombstonesRemainIndependent() {
        sql("insert into physiology_sleep_overrides(user_id,device_id,original_start_at,original_end_at,start_at,end_at,tombstone) " +
            "values('$user','$device','2026-09-17 01:00Z','2026-09-17 02:00Z','2026-09-17 01:00Z','2026-09-17 02:00Z',true)")
        publish(payload(claim()))
        val other = UUID.randomUUID()
        sql("insert into devices(id,user_id) values ('$other','$user')")
        publish(payload(claim(other)))
        assertEquals(2L, count("server_physiology_results"))
        assertEquals(1L, number("select count(*) from physiology_sleep_overrides where user_id='$user' and tombstone"))
    }

    @Test fun corruptOwnerEnvelopeCannotPublish() {
        val item = claim()
        val bad = payload(item).apply { getJSONObject("daily").put("source_device_id",UUID.randomUUID().toString()) }
        expectFailure("22023") { publish(bad) }
        assertEquals(0L, count("server_physiology_results"))
    }

    @Test fun archiveFailureIsIndependentlyRetryableAndFenced() {
        publish(payload(claim()))
        val outbox = DerivedArchiveOutbox(db, DerivedArtifactWriter(null,"http://127.0.0.1:1","unused"))
        val first = outbox.claimOne(user)!!
        assertTrue(outbox.finish(first,null,"controlled_failure"))
        assertEquals(1L,count("server_physiology_results"))
        sql("update physiology_archive_outbox set next_attempt_at=clock_timestamp() where id=${first.id}")
        val next = outbox.claimOne(user)!!
        assertEquals(first.key,next.key)
        assertEquals(first.payload.toMap(),next.payload.toMap())
        assertFalse(outbox.finish(first,"a".repeat(64),null))
        assertTrue(outbox.finish(next,"b".repeat(64),null))
    }

    @Test fun shadowCannotBeSelectedAndAnotherOwnerCannotReadSnapshots() {
        publish(payload(claim()))
        val other = UUID.randomUUID()
        sql("insert into auth.users values ('$other')")
        db.withConnection { c ->
            c.createStatement().use { s ->
                s.execute("grant usage on schema auth to authenticated")
                s.execute("grant select on devices to authenticated")
                s.execute("set role authenticated")
                s.execute("select set_config('request.jwt.claim.sub','$other',false)")
                s.executeQuery("select count(*) from server_physiology_results where user_id='$user'").use { r ->
                    r.next(); assertEquals(0,r.getInt(1))
                }
                expectFailure("42501") { s.execute("select server_scoring_for_day('$user','$day')") }
                s.execute("select set_config('request.jwt.claim.sub','$user',false)")
                expectFailure("22023") {
                    s.execute("select select_physiology_source('sleep','$device','frwhoop-physiology-2')")
                }
                s.execute("reset role")
            }
        }
    }

    @Test fun selectedRevisionFreshnessDoesNotExpireHistoricalResultsByWallClockAge() {
        val version="frwhoop-physiology-2"
        selectSyntheticQualifiedV2()
        val claim=claim()
        publish(payload(claim).put("algorithm_version",version).put("publication_status","final"))
        fun read(): JSONObject = db.withConnection { c ->
            c.createStatement().use { s ->
                s.execute("grant usage on schema auth to authenticated")
                s.execute("grant select on devices,server_daily_scores,server_sleep_nights to authenticated")
                s.execute("set role authenticated")
                s.execute("select set_config('request.jwt.claim.sub','$user',false)")
                try { s.executeQuery("select server_scoring_for_day('$user','$day')").use { r ->
                    r.next(); JSONObject(r.getString(1))
                } } finally { s.execute("reset role") }
            }
        }
        val fresh=read()
        assertFalse(fresh.getBoolean("stale"))
        assertEquals(device.toString(),fresh.getJSONObject("daily").getString("source_device_id"))
        assertEquals(version,fresh.getString("algorithm_version"))
        queue.dirtyWorkItem(user,device,day)
        assertTrue(read().getBoolean("stale"))
    }

    @Test fun freshUnavailableCalendarResultRetainsReasonWithoutClaimingStaleOrAvailable() {
        val item=claim()
        selectSyntheticQualifiedV2()
        publish(payload(item).put("algorithm_version","frwhoop-physiology-2")
            .put("unavailable_reason","calendar_date_has_no_owned_time"))
        db.withConnection { c -> c.createStatement().use { s ->
            s.execute("grant usage on schema auth to authenticated")
            s.execute("grant select on devices,server_daily_scores,server_sleep_nights to authenticated")
            s.execute("set role authenticated")
            s.execute("select set_config('request.jwt.claim.sub','$user',false)")
            try { s.executeQuery("select server_scoring_for_day('$user','$day')").use { rows ->
                rows.next(); val read=JSONObject(rows.getString(1))
                assertFalse(read.getBoolean("stale"))
                for(feature in listOf("hrv","sleep","respiration")) {
                    val value=read.getJSONObject("features").getJSONObject(feature)
                    assertEquals("unavailable",value.getString("status"))
                    assertEquals("calendar_date_has_no_owned_time",value.getString("reason"))
                }
            } } finally { s.execute("reset role") }
        } }
    }

    @Test fun invalidEpisodeAndMeasurementEnvelopeAreRejectedBeforeWrite() {
        val item=claim()
        val missing=payload(item,1).apply { getJSONArray("nights").getJSONObject(0).remove("start_at") }
        expectFailure("22023") { publish(missing) }
        val overlap=payload(item,2).apply {
            getJSONArray("nights").getJSONObject(1).put("start_at","2026-09-17T00:15:00Z")
        }
        expectFailure("22023") { publish(overlap) }
        val wrongOwner=payload(item).put("measurements",JSONArray().put(JSONObject()
            .put("user_id",UUID.randomUUID().toString()).put("device_id",device.toString())))
        expectFailure("22023") { publish(wrongOwner) }
        assertEquals(0L,count("server_physiology_results"))
    }

    @Test fun fiveMinuteHeartRateReadbackFollowsHrvDeviceAndOwnerSelection() {
        selectSyntheticQualifiedV2()
        val secondary = UUID.randomUUID()
        sql("insert into devices(id,user_id) values('$secondary','$user')")
        for ((ownerDevice, mean) in listOf(device to 60, secondary to 120)) {
            val item = claim(ownerDevice)
            val value = payload(item).apply { getJSONObject("daily").put("heart_rate_windows", JSONArray().put(
                JSONObject().put("start",1789606800).put("end",1789607100)
                    .put("user_id",user.toString()).put("device_id",ownerDevice.toString())
                    .put("method_version","sampled-hr-five-minute-2").put("mean_bpm",mean))) }
            publish(value)
        }
        sql("update physiology_source_selection set device_id='$secondary' where user_id='$user' and feature='respiration'")
        val otherUser = UUID.randomUUID()
        sql("insert into auth.users values('$otherUser')")
        db.withConnection { c -> c.createStatement().use { s ->
            s.execute("grant usage on schema auth to authenticated")
            s.execute("grant select on devices,server_daily_scores,server_sleep_nights to authenticated")
            s.execute("set role authenticated")
            try {
                s.execute("select set_config('request.jwt.claim.sub','$user',false)")
                s.executeQuery("select server_scoring_for_day('$user','$day')").use { rows ->
                    rows.next(); val read = JSONObject(rows.getString(1))
                    val window = read.getJSONObject("daily").getJSONArray("heart_rate_windows").getJSONObject(0)
                    assertEquals(60,window.getInt("mean_bpm"))
                    assertEquals(device.toString(),window.getString("device_id"))
                    assertEquals(user.toString(),window.getString("user_id"))
                    assertEquals(secondary.toString(),read.getJSONObject("features").getJSONObject("respiration").getString("device_id"))
                }
                s.execute("select set_config('request.jwt.claim.sub','$otherUser',false)")
                expectFailure("42501") { s.execute("select server_scoring_for_day('$user','$day')") }
                s.executeQuery("select count(*) from server_physiology_results where user_id='$user'").use { it.next(); assertEquals(0,it.getInt(1)) }
            } finally { s.execute("reset role"); s.execute("select set_config('request.jwt.claim.sub','',false)") }
        } }
    }

    @Test fun heartRateWindowCannotSmuggleAnotherOwnerOrDeviceIntoPublishedResult() {
        val item = claim()
        for ((owner, ownerDevice) in listOf(UUID.randomUUID() to device, user to UUID.randomUUID())) {
            val value = payload(item).apply { getJSONObject("daily").put("heart_rate_windows", JSONArray().put(
                JSONObject().put("start",1789606800).put("end",1789607100)
                    .put("user_id",owner.toString()).put("device_id",ownerDevice.toString())
                    .put("method_version","sampled-hr-five-minute-2").put("mean_bpm",60))) }
            expectFailure("22023") { publish(value) }
        }
        assertEquals(0L,count("server_physiology_results"))
    }

    @Test fun readerLoadsAfternoonContextAndEditsWithoutTreatingAnnotationsAsTruth() {
        val at=java.time.Instant.parse("2026-09-17T15:00:00Z").epochSecond
        sql("insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) " +
            "values('$user','$device','${UUID.randomUUID()}',$at,60,'${UUID.randomUUID()}')")
        sql("insert into noop_event_labels(user_id,device_id,label,start_ts,end_ts,source,confidence,updated_at) " +
            "values('$user','$device','reading',$at,${at+600},'patient','confirmed','2026-09-17T16:00:00.900Z')," +
            "('$user','$device','sleep',${at+600},${at+1200},'instrumented','confirmed','2026-09-17T16:00:00.900Z')")
        sql("insert into physiology_sleep_overrides(user_id,device_id,original_start_at,original_end_at,start_at,end_at) " +
            "values('$user','$device',to_timestamp($at),to_timestamp(${at+1200}),to_timestamp($at),to_timestamp(${at+1500}))")
        val input=com.frwhoop.scoring.db.SignalSampleReader(db).loadDay(user,day,device,"UTC")!!
        assertEquals(listOf(at),input.hr.map { it.ts })
        assertEquals(2,input.sleepContext.size)
        assertTrue(input.sleepContext.none { it.qualifiedBinarySleep })
        // The timestamp contract is whole seconds; casting numeric epochs to bigint rounds ahead.
        assertTrue(input.sleepContext.all { it.availableAt==java.time.Instant.parse("2026-09-17T16:00:00Z").epochSecond })
        assertEquals(at+1500,input.sleepOverrides.single().end)
        val result=com.frwhoop.scoring.scoring.DayScorer().score(input,"frwhoop-physiology-2","9",
            java.time.Instant.parse("2026-09-17T16:00:00.950Z"))
        val night=com.frwhoop.scoring.scoring.CanonicalScorePayload.build(result).getJSONArray("nights").getJSONObject(0)
        assertTrue(night.getBoolean("manual_edit"))
        assertEquals(0.0,night.getDouble("asleep_min"),0.0) // Explicit awake annotation, not missing-data zero.
        assertEquals(10.0,night.getDouble("awake_min"),0.0)
        assertEquals(15.0,night.getDouble("state_unknown_min"),0.0)
    }

    @Test fun manualRpcIsOwnerScopedOptimisticAndKeepsTombstones() {
        val id=UUID.randomUUID()
        db.withConnection { c -> c.createStatement().use { s ->
            s.execute("grant usage on schema auth to authenticated")
            s.execute("set role authenticated")
            s.execute("select set_config('request.jwt.claim.sub','$user',false)")
            val args="'$id','$device','2026-09-17T01:00Z','2026-09-17T02:00Z','2026-09-17T01:10Z','2026-09-17T02:10Z'"
            try {
                s.execute("select set_physiology_sleep_override($args,false,0)")
                expectFailure("40001") { s.execute("select set_physiology_sleep_override($args,false,0)") }
                s.execute("select set_physiology_sleep_override($args,true,1)")
                expectFailure("40001") { s.execute("select set_physiology_sleep_override($args,false,1)") }
                s.execute("select set_config('request.jwt.claim.sub','${UUID.randomUUID()}',false)")
                expectFailure("42501") { s.execute("select set_physiology_sleep_override($args,false,2)") }
            } finally { s.execute("reset role") }
        } }
        assertEquals(1L,number("select count(*) from physiology_sleep_overrides where id='$id' and revision=2 and tombstone"))
    }

    @Test fun readbackShowsLiveOverrideRevisionAndArchiveStateWithoutAnotherPublication() {
        val item=claim()
        selectSyntheticQualifiedV2()
        publish(payload(item).put("algorithm_version","frwhoop-physiology-2"))
        val id=UUID.randomUUID()
        db.withConnection { c -> c.createStatement().use { s ->
            s.execute("grant usage on schema auth to authenticated")
            s.execute("grant select on devices,server_daily_scores,server_sleep_nights to authenticated")
            s.execute("set role authenticated")
            s.execute("select set_config('request.jwt.claim.sub','$user',false)")
            try {
                s.execute("select set_physiology_sleep_override('$id','$device','2026-09-17T01:00Z','2026-09-17T02:00Z',"+
                    "'2026-09-17T01:10Z','2026-09-17T02:10Z',false,0)")
                s.executeQuery("select server_scoring_for_day('$user','$day')").use { rows ->
                    rows.next(); val read=JSONObject(rows.getString(1))
                    val override=read.getJSONArray("sleep_overrides").getJSONObject(0)
                    assertEquals(id.toString(),override.getString("id"))
                    assertEquals(1,override.getInt("revision"))
                    assertEquals(device.toString(),override.getString("device_id"))
                    val sleep=read.getJSONObject("features").getJSONObject("sleep")
                    assertEquals("pending",sleep.getString("archive_status"))
                    assertEquals("UTC",sleep.getString("timezone_id"))
                    assertTrue(sleep.getBoolean("supports_boundary_overrides"))
                    assertTrue(read.getBoolean("stale"))
                }
            } finally { s.execute("reset role") }
        } }
        assertEquals(1L,count("server_physiology_results"))
    }

    /** Disposable fixture qualification exercises selected readback; it is not scientific evidence. */
    private fun selectSyntheticQualifiedV2() {
        sql("update physiology_feature_qualifications set qualification='reference_qualified'," +
            "policy_sha256=repeat('a',64),evaluation_sha256=repeat('b',64)," +
            "signed_policy=jsonb_build_object('payload',jsonb_build_object('metric_family',feature)," +
            "'signature',jsonb_build_object('algorithm','HMAC-SHA256'))," +
            "signed_evaluation=jsonb_build_object('payload',jsonb_build_object('policy_sha256',repeat('a',64))," +
            "'signature',jsonb_build_object('algorithm','HMAC-SHA256')),reviewed_by='disposable-test',reviewed_at=now() " +
            "where algorithm_version='frwhoop-physiology-2'")
        sql("insert into physiology_source_selection(user_id,feature,device_id,algorithm_version) " +
            "select '$user',feature,'$device','frwhoop-physiology-2' from physiology_feature_defaults")
    }

    private fun claim(selectedDevice: UUID = device): ScoringWorkQueue.WorkItem {
        queue.dirtyWorkItem(user,selectedDevice,day)
        sql("update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='$user' and device_id='$selectedDevice'")
        return queue.claimOne(user,selectedDevice,day)!!
    }

    private fun payload(item: ScoringWorkQueue.WorkItem, episodes: Int = 0): JSONObject = JSONObject()
        .put("schema_version",2).put("user_id",item.userId.toString()).put("device_id",item.deviceId.toString())
        .put("day",day).put("algorithm_version","frwhoop-physiology-2")
        .put("input_revision",item.inputRevision).put("lease_token",item.leaseToken.toString())
        .put("run_id",item.runId.toString()).put("computed_at","2026-09-18T00:00:00Z")
        .put("publication_status","provisional")
        .put("daily",JSONObject().put("day",day).put("source_device_id",item.deviceId.toString()))
        .put("nights",JSONArray((0 until episodes).map { index -> JSONObject()
            .put("device_id",item.deviceId.toString()).put("period_day",day)
            .put("start_at","2026-09-17T0${index}:00:00Z").put("end_at","2026-09-17T0${index}:30:00Z") }))
        .put("measurements",JSONArray())

    private fun publish(payload: JSONObject) { db.withConnection { c ->
        c.prepareStatement("select engine_publish_physiology('test',?::jsonb)").use { p ->
            p.setString(1,payload.toString()); p.execute()
        }
    } }
    private fun sql(query: String) { db.withConnection { c -> c.createStatement().use { it.execute(query) } } }
    private fun count(table: String): Long = number("select count(*) from $table where user_id='$user'")
    private fun number(query: String): Long = db.withConnection { c ->
        c.createStatement().use { s -> s.executeQuery(query).use { r -> r.next(); r.getLong(1) } }
    }
    private fun expectFailure(state: String, operation: () -> Unit) {
        try { operation(); fail("expected SQLSTATE $state") }
        catch (error: SQLException) { assertEquals(state,error.sqlState) }
    }
}
