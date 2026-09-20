package com.frwhoop.scoring

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class RawInvalidationBatchIntegrationTest:PgIntegrationBase() {
    @Test fun bulkRawUploadCoalescesInvalidationWithoutPerSampleTimezoneCatalogEnumeration() {
        val ts=Instant.parse("2026-11-01T05:00:00Z").epochSecond
        sql("update profiles set timezone='America/New_York' where id='$u'")
        pg.connection().use { c ->
            c.createStatement().use { s ->
                s.execute("set statement_timeout='8s'")
                s.execute("""insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id)
                    select '$u','$device',gen_random_uuid(),$ts+n,60,gen_random_uuid() from generate_series(0,4999) n""")
            }
        }
        assertEquals("5000",scalar("select count(*) from noop_hr_samples"))
        assertEquals("3",scalar("select count(*) from scoring_jobs_v2 where algorithm_version='frwhoop-server-1'"))
        assertEquals("2026-11-01",scalar("select min(day)::text from scoring_jobs_v2"))
        val before=scalar("select sum(input_revision) from scoring_jobs_v2")
        sql("update noop_hr_samples set source_id=gen_random_uuid(),batch_id=gen_random_uuid()")
        assertEquals("transport-only retry must remain a no-op",before,scalar("select sum(input_revision) from scoring_jobs_v2"))
    }
}
