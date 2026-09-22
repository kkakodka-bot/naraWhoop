package com.frwhoop.scoring

import org.junit.Assert.*
import org.junit.Test

/** Native replacement for the former SQL-string assertions. */
class ScoringWorkQueueSqlTest : PgIntegrationBase() {
    @Test fun discoveryGroupsByUserDeviceAndLocalDay() {
        sql("update profiles set timezone='America/Los_Angeles' where id='$u'")
        sql("""insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
            values('$u','$device','$u',extract(epoch from timestamptz '2026-09-16T05:00:00Z'),60,'$u')""")
        assertEquals("2026-09-15",scalar("select min(day)::text from scoring_jobs_v2"))
        assertEquals("2026-09-17",scalar("select max(day)::text from scoring_jobs_v2"))
        assertEquals("3",scalar("select count(*) from scoring_jobs_v2"))
    }

    @Test fun eventOnlyChangesAndCorrectionsInvalidateButDuplicateReplayDoesNot() {
        sql("""insert into noop_events(user_id,device_id,source_id,ts,kind,"payloadJSON",batch_id)
            values('$u','$device','$u',1789470000,'WRIST_OFF(10)','{}','$u')""")
        assertEquals("3",scalar("select count(*) from scoring_jobs_v2"))
        sql("""update noop_events set "payloadJSON"="payloadJSON",batch_id='$other'""")
        assertEquals("1",scalar("select max(input_revision) from scoring_jobs_v2"))
        sql("""update noop_events set "payloadJSON"='{"corrected":true}'""")
        assertEquals("2",scalar("select max(input_revision) from scoring_jobs_v2"))
        sql("delete from noop_events")
        assertEquals("3",scalar("select max(input_revision) from scoring_jobs_v2"))
    }

    @Test fun profileChangeFencesInflightResultsBeforeBoundedExpansion() {
        queue.dirtyWorkItem(u,device,day); val claimed=queue.claim()!!
        sql("update profiles set timezone='America/New_York' where id='$u'")
        assertNull(queue.publish(claimed,payload(),1))
        queue.markFailed(claimed,"changed")
        assertNull(queue.claim())
        queue.maintain(10)
        assertNotNull(queue.claim())
    }

    @Test fun uncommittedStreamTransactionCannotBeLostBehindDiscoveryWatermark() {
        pg.connection().use { c ->
            c.autoCommit=false
            c.createStatement().use { s ->
                s.execute("""insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id,ingested_at)
                    values('$u','$device','$u',1789470000,60,'$u',clock_timestamp()-interval '2 hours')""")
                assertEquals("0",scalar("select count(*) from scoring_jobs_v2"))
                c.commit()
            }
        }
        assertEquals("3",scalar("select count(*) from scoring_jobs_v2"))
    }

    @Test fun longIndexedObjectSpanCreatesBoundedResumableInvalidation() {
        sql("""insert into object_manifests(id,user_id,device_id,object_kind,object_key)
            values('$device','$u','$device','ppg_raw','fixture/raw-span')""")
        sql("""insert into noop_signal_windows(user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts)
            values('$u','$device','ppg',0,'$device','fixture/raw-span',
              extract(epoch from timestamptz '2026-01-01'),extract(epoch from timestamptz '2026-09-01'))""")
        assertEquals("0",scalar("select count(*) from scoring_jobs_v2"))
        assertEquals("1",scalar("select count(*) from scoring_invalidations_v2"))
        assertEquals("4",scalar("select expand_scoring_invalidations_v2(4)"))
        assertEquals("4",scalar("select count(*) from scoring_jobs_v2"))
        assertEquals("2026-01-05",scalar("select next_day::text from scoring_invalidations_v2"))
    }

    @Test fun movedSessionInvalidatesBothOldAndNewWakeDays() {
        sql("""insert into sessions(id,user_id,device_id,kind,start_at,end_at)
            values('$device','$u','$device','sleep','2026-09-01T23:00:00Z','2026-09-02T07:00:00Z')""")
        sql("update sessions set start_at='2026-09-05T23:00:00Z',end_at='2026-09-06T07:00:00Z'")
        assertEquals("2",scalar("select input_revision from scoring_jobs_v2 where day='2026-09-02'"))
        assertEquals("1",scalar("select input_revision from scoring_jobs_v2 where day='2026-09-06'"))
    }

    @Test fun boundedReconciliationRepairsMissingEventOnlyJobsWithoutRedirtyingExistingResults() {
        sql("alter table noop_events disable trigger scoring_insert_v2")
        try {
            sql("""insert into noop_events(user_id,device_id,source_id,ts,kind,"payloadJSON",batch_id)
                values('$u','$device','$u',1789470000,'WRIST_OFF(10)','{}','$u')""")
        } finally { sql("alter table noop_events enable trigger scoring_insert_v2") }
        assertEquals("0",scalar("select count(*) from scoring_jobs_v2"))
        val first=org.json.JSONObject(scalar("select reconcile_scoring_days_v2('$u','$device','$day','2026-09-18',1)"))
        assertEquals(1,first.getInt("repaired")); assertFalse(first.getBoolean("done"))
        assertEquals("2026-09-16",first.getString("nextDay"))
        val repeated=org.json.JSONObject(scalar("select reconcile_scoring_days_v2('$u','$device','$day','2026-09-18',1)"))
        assertEquals(0,repeated.getInt("repaired"))
        assertEquals("1",scalar("select input_revision from scoring_jobs_v2"))
    }
}
