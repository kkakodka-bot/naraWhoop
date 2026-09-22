package com.frwhoop.scoring

import com.frwhoop.scoring.db.LeaseHeartbeat
import com.frwhoop.scoring.db.ScoringWorkQueue
import org.junit.Assert.*
import org.junit.Test
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class ScoringConcurrencyIntegrationTest : PgIntegrationBase() {
    @Test fun uncommittedConfigurationChangeSerializesBeforePublication() {
        queue.dirtyWorkItem(u,device,day)
        val item=queue.claim()!!
        val executor=Executors.newSingleThreadExecutor()
        try {
            pg.connection().use { c ->
                c.autoCommit=false
                c.createStatement().use { it.execute("update profiles set timezone='Pacific/Auckland' where id='$u'") }
                val publish=executor.submit<Long?> { queue.publish(item,payload(),1) }
                val deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5)
                while (scalar("select count(*) from pg_locks where locktype='advisory' and not granted")=="0" &&
                    !publish.isDone && System.nanoTime()<deadline) Thread.sleep(10)
                assertFalse("publisher must wait for the in-flight input transaction",publish.isDone)
                assertEquals("1",scalar("select count(*) from pg_locks where locktype='advisory' and not granted"))
                c.commit()
                assertNull(publish.get(5,TimeUnit.SECONDS))
                assertEquals("0",scalar("select count(*) from scoring_snapshots_v2"))
            }
        } finally { executor.shutdownNow() }
    }

    @Test fun renewalThreadKeepsRealOneSecondLeaseAliveDuringSlowWork() {
        val q=ScoringWorkQueue(pg.db,claimLease=Duration.ofSeconds(1))
        q.dirtyWorkItem(u,device,day); val item=q.claim()!!
        val renewed=CountDownLatch(4)
        LeaseHeartbeat(q.claimLease) {
            q.renew(item).also { if(it) renewed.countDown() }
        }.use { guard ->
            assertTrue(renewed.await(5,TimeUnit.SECONDS))
            guard.requireValid()
            assertNull(q.claim())
            assertNotNull(q.publish(item,payload(),1))
        }
        assertTrue(scalar("select renewal_count from scoring_jobs_v2")!!.toLong()>=4)
    }

    @Test fun disabledVersionCannotPublishAndMetricsExposePendingWork() {
        queue.dirtyWorkItem(u,device,day); val item=queue.claim()!!
        sql("update scoring_algorithms_v2 set enabled=false")
        try {
            assertNull(queue.publish(item,payload(),1))
            assertEquals(1,queue.metrics().getInt("pending"))
            assertEquals(1,queue.metrics().getInt("running"))
            assertEquals(1,queue.metrics().getInt("claims"))
        } finally { sql("update scoring_algorithms_v2 set enabled=true") }
    }

    @Test fun explicitSourceSelectionAndAuthoritativeNoDataNeverMergeDevices() {
        queue.dirtyWorkItem(u,device,day); queue.publish(queue.claim()!!,payload(),1)
        sql("select set_scoring_source_v2('$u','$device2')")
        assertEquals(device2.toString(),scalar("select selected_scoring_device_v2('$u','$day','frwhoop-server-1')"))
        queue.maintain(10)
        val item=queue.claim()!!
        assertEquals(device2,item.deviceId)
        assertNotNull(queue.publish(item,payload().put("status","no_data")
            .put("dataThrough",org.json.JSONObject.NULL).put("daily",org.json.JSONObject.NULL),1))
        assertNull(scalar("select hrv_rmssd_ms from server_daily_scores"))
        assertEquals(device2.toString(),scalar("select source_device_id from server_daily_scores"))
    }

    @Test fun algorithmRegistrationBeforeLegacyRepairStillSchedulesBothVersions() {
        sql("select register_scoring_algorithm_v2('frwhoop-server-2')")
        sql("insert into scoring_work_items(user_id,device_id,day,attempts) values('$u','$device','$day',8)")
        queue.maintain(1)
        assertEquals("2",scalar("select count(*) from scoring_jobs_v2"))
    }
}
