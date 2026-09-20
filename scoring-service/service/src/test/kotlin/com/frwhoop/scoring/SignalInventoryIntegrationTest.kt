package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.SignalInventoryReader
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.util.UUID

class SignalInventoryIntegrationTest {
    private lateinit var db: PostgresClient
    private val user = UUID.randomUUID()
    private val device = UUID.randomUUID()
    private val otherDevice = UUID.randomUUID()
    private val start = Instant.parse("2026-08-18T01:00:00Z").epochSecond

    @Before fun setup() {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh", url != null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db = PostgresClient(url)
        sql("insert into auth.users values('$user')")
        sql("insert into profiles(id,timezone) values('$user','UTC')")
        sql("insert into devices(id,user_id) values('$device','$user'),('$otherDevice','$user')")
    }
    @After fun close() { if (::db.isInitialized) db.close() }

    @Test fun occupiedBinsAreScopedAndNeverClaimContinuousAcquisitionOrMutateWork() {
        hr(device, start); hr(device, start + 1); hr(device, start + 60); hr(otherDevice, start + 2)
        val revision = scalar("select jsonb_object_agg(day,input_revision)::text from physiology_work_items where user_id='$user' and device_id='$device'")
        val report = SignalInventoryReader(db).report(user, device, "2026-08-18", start to start + 60)
        assertTrue(report.getBoolean("read_only"))
        assertFalse(report.getBoolean("signal_values_exported"))
        assertFalse(report.getBoolean("waveform_activation_allowed"))
        val hr = report.getJSONObject("signals").getJSONObject("heart_rate")
        assertEquals(2, hr.getInt("row_count"))
        assertEquals(2, hr.getInt("occupied_seconds"))
        assertEquals(2.0 / 60.0, hr.getDouble("occupied_second_fraction"), 1e-12)
        assertEquals(58, hr.getInt("maximum_empty_second_run"))
        assertTrue(hr.isNull("observed_time_fraction"))
        assertTrue(hr.isNull("sample_rate_hz"))
        assertTrue(hr.isNull("timing_uncertainty_seconds"))
        assertEquals(60, report.getJSONObject("signals").getJSONObject("rr_intervals").getInt("maximum_empty_second_run"))
        assertEquals(revision, scalar("select jsonb_object_agg(day,input_revision)::text from physiology_work_items where user_id='$user' and device_id='$device'"))
    }

    @Test fun ownershipAndCalendarBoundsCannotBorrowAnotherPeriod() {
        assertThrows(IllegalArgumentException::class.java) { SignalInventoryReader(db).report(UUID.randomUUID(), device, "2026-08-18") }
        assertThrows(IllegalArgumentException::class.java) { SignalInventoryReader(db).report(user, device, "2026-08-18", start - 5 * 86400 to start) }
        sql("update scoring_timezone_history set timezone_id='America/Los_Angeles' where user_id='$user'")
        val report = SignalInventoryReader(db).report(user, device, "2026-03-08")
        assertEquals((24 + 23) * 3600L, report.getLong("period_seconds"))
        assertEquals("America/Los_Angeles", report.getJSONArray("timezone_ids").getString(0))
    }

    @Test fun RawCatalogueClaimsDoNotBecomeVerifiedCoverageOrPruningPermission() {
        val id = UUID.randomUUID()
        val key = "inventory-fixture/$id"
        sql("insert into object_manifests(id,user_id,device_id,object_key,status,sha256_source,sha256,compression,format,object_class) " +
            "values('$id','$user','$device','$key','ready','client_claimed',repeat('a',64),'gzip','bin_gzip_noop_push_v1','raw')")
        sql("insert into noop_signal_windows(user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts,received_records,coverage) " +
            "values('$user','$device','ppgWaveformSample',$start,'$id','$key',$start,${start + 60},2,1)")
        val report = SignalInventoryReader(db).report(user, device, "2026-08-18", start to start + 60)
        val raw = report.getJSONArray("raw_objects").getJSONObject(0)
        assertEquals(1.0, raw.getDouble("catalogue_reported_coverage"), 0.0)
        assertTrue(raw.isNull("observed_time_fraction"))
        assertEquals("unqualified", raw.getString("channel_identity"))
        assertEquals("catalogue_only_not_refetched_by_inventory", raw.getString("proof_scope"))
        assertEquals("not_established", report.getJSONObject("retention").getString("local_pruning_guarantee"))
        assertEquals("client_claimed", scalar("select sha256_source from object_manifests where id='$id'"))
        assertEquals("0", scalar("select count(*)::text from object_manifests where id='$id' and decode_verified_at is not null"))
    }

    private fun hr(ownerDevice: UUID, ts: Long) = sql("insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) " +
        "values('$user','$ownerDevice','$ownerDevice',$ts,55,'${UUID.randomUUID()}')")
    private fun sql(query: String) = db.withConnection { it.createStatement().use { s -> s.execute(query) } }
    private fun scalar(query: String) = db.withConnection { it.createStatement().use { s -> s.executeQuery(query).use { r -> r.next(); r.getString(1) } } }
}
