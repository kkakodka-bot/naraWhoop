package com.frwhoop.scoring

import com.frwhoop.scoring.db.ScoringWorkQueue
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.TimeUnit

class ScoringDurabilityIntegrationTest : PgIntegrationBase() {
    @Test fun moreThanOneHundredSuccessfulGenerationsNeverExhaustFailures() {
        var last = 0L
        repeat(125) { n ->
            assertEquals((n+1).toLong(),queue.dirtyWorkItem(u,device,day))
            val item = queue.claim()!!
            val revision = queue.publish(item,payload(n.toDouble()),1)!!
            assertTrue(revision>last); last=revision
            assertNull(queue.claim())
        }
        assertEquals("125",scalar("select success_count from scoring_jobs_v2"))
        assertEquals("0",scalar("select consecutive_failures from scoring_jobs_v2"))
        assertEquals("125",scalar("select count(*) from scoring_archive_jobs_v2"))
    }

    @Test fun expiredWorkerCannotRenewFailOrPublishOverReplacement() {
        queue.dirtyWorkItem(u,device,day)
        val old = queue.claim()!!
        sql("update scoring_jobs_v2 set lease_until=clock_timestamp()-interval '1 second'")
        val current = queue.claim()!!
        assertNotEquals(old.leaseToken,current.leaseToken)
        assertFalse(queue.renew(old)); assertFalse(queue.markFailed(old,"late"))
        assertNull(queue.publish(old,payload(99.0),1))
        assertNotNull(queue.publish(current,payload(42.0),1))
        assertNull(queue.publish(old,payload(99.0),1))
        assertEquals(42.0,scalar("select hrv_rmssd_ms from server_daily_scores")!!.toDouble(),0.0)
    }

    @Test fun arrivalsWhileRunningFencePublicationAndPreserveNewGeneration() {
        queue.dirtyWorkItem(u,device,day); val old=queue.claim()!!
        queue.dirtyWorkItem(u,device,day)
        assertNull(queue.publish(old,payload(),1))
        assertTrue(queue.markFailed(old,"superseded"))
        assertEquals("0",scalar("select consecutive_failures from scoring_jobs_v2"))
        val current=queue.claim()!!; assertEquals(2,current.inputRevision)
        assertNotNull(queue.publish(current,payload(),1))
    }

    @Test fun concurrentConsumersClaimEachJobOnceAndOnlyWhenRunnable() {
        repeat(12) { queue.dirtyWorkItem(u,device,"2026-09-${(it+1).toString().padStart(2,'0')}") }
        val pool=Executors.newFixedThreadPool(6)
        try {
            val gate=CyclicBarrier(6)
            val claimed=pool.invokeAll((1..6).map { Callable { gate.await(10,TimeUnit.SECONDS); queue.claim()!! } }).map { it.get() }
            assertEquals(6,claimed.map { it.leaseToken }.toSet().size)
            assertEquals(6,claimed.map { it.day }.toSet().size)
            assertEquals("6",scalar("select count(*) from scoring_jobs_v2 where lease_token is null"))
        } finally { pool.shutdownNow() }
    }

    @Test fun successfulRenewalMovesDeadlineAndBlocksOtherConsumer() {
        queue.dirtyWorkItem(u,device,day); val item=queue.claim()!!
        sql("update scoring_jobs_v2 set lease_until=clock_timestamp()+interval '1 second'")
        assertTrue(queue.renew(item)); assertNull(queue.claim())
        assertEquals("1",scalar("select renewal_count from scoring_jobs_v2"))
    }

    @Test fun failuresBackOffAndDeadLetterButNewInputRecovers() {
        queue.dirtyWorkItem(u,device,day)
        repeat(8) {
            val item=queue.claim()!!; assertTrue(queue.markFailed(item,"fixture_failure"))
            assertNull(queue.claim())
            assertEquals("t",scalar("select not_before>clock_timestamp() from scoring_jobs_v2"))
            sql("update scoring_jobs_v2 set not_before=clock_timestamp()-interval '1 second'")
        }
        assertNull(queue.claim()); assertEquals("t",scalar("select dead_letter from scoring_jobs_v2"))
        queue.dirtyWorkItem(u,device,day); assertNotNull(queue.claim())
    }

    @Test fun publicationRollsBackSnapshotArchiveAndSettlementTogether() {
        queue.dirtyWorkItem(u,device,day); val item=queue.claim()!!
        val malformed=night().put("start_at","invalid-time")
        assertThrows(java.sql.SQLException::class.java) { queue.publish(item,payload(sleep=JSONArray().put(malformed)),1) }
        assertEquals("0",scalar("select count(*) from scoring_snapshots_v2"))
        assertEquals("0",scalar("select count(*) from scoring_archive_jobs_v2"))
        assertEquals("0",scalar("select completed_revision from scoring_jobs_v2"))
        assertNotNull(queue.publish(item,payload(),1))
    }

    @Test fun deviceOrderDoesNotChooseResultAndSleepReplacementRemovesShiftedAndDeletedSessions() {
        queue.dirtyWorkItem(u,device2,day); queue.dirtyWorkItem(u,device,day)
        val first=queue.claim()!!; val second=queue.claim()!!
        for (item in listOf(first,second).sortedByDescending { it.deviceId }) {
            queue.publish(item,payload(if(item.deviceId==device) 42.0 else 80.0,JSONArray().put(night())),1)
        }
        assertEquals(device.toString(),scalar("select source_device_id from server_daily_scores"))
        assertEquals("2",scalar("select count(*) from scoring_snapshots_v2"))
        queue.dirtyWorkItem(u,device,day)
        queue.publish(queue.claim()!!,payload(sleep=JSONArray().put(night("2026-09-15T01:00:00Z"))),1)
        assertEquals("1",scalar("select count(*) from server_sleep_nights"))
        queue.dirtyWorkItem(u,device,day); queue.publish(queue.claim()!!,payload(),1)
        assertEquals("0",scalar("select count(*) from server_sleep_nights"))
        assertEquals("4",scalar("select count(*) from scoring_snapshots_v2"))
        assertThrows(java.sql.SQLException::class.java) { sql("update scoring_snapshots_v2 set payload='{}'") }
    }

    @Test fun newAlgorithmGetsExistingDaysAndStrandedLegacyRepairIsBoundedIdempotent() {
        sql("insert into scoring_work_items(user_id,device_id,day,attempts) values('$u','$device','$day',8)")
        queue.maintain(1)
        assertNotNull(queue.publish(queue.claim()!!,payload(),1))
        queue.maintain(1); assertNull(queue.claim())
        val newer=ScoringWorkQueue(pg.db,"frwhoop-server-2")
        newer.maintain(1); val item=newer.claim()!!
        assertEquals("frwhoop-server-2",item.algorithmVersion)
        assertNotNull(newer.publish(item,payload(),1))
        assertEquals("2",scalar("select count(*) from scoring_snapshots_v2"))
    }

    @Test fun authenticatedRpcSelectsOnlyOwnResultAndPreservesPendingSnapshot() {
        queue.dirtyWorkItem(u,device,day); queue.publish(queue.claim()!!,payload(),1)
        queue.dirtyWorkItem(u,device,day)
        pg.connection().use { c ->
            c.createStatement().use { s ->
                s.execute("set role authenticated; select set_config('request.jwt.claim.sub','$u',false)")
                s.executeQuery("select get_server_score_snapshot_v2('$day')").use { r ->
                    r.next(); val result=JSONObject(r.getString(1)); assertEquals(2,result.getInt("schemaVersion"))
                    assertEquals(device.toString(),result.getString("sourceDeviceId")); assertTrue(result.getBoolean("pending"))
                }
                s.execute("select set_config('request.jwt.claim.sub','$other',false)")
                s.executeQuery("select get_server_score_snapshot_v2('$day')").use { r ->
                    r.next(); assertTrue(JSONObject(r.getString(1)).isNull("daily"))
                }
                assertThrows(java.sql.SQLException::class.java) { s.executeQuery("select * from scoring_snapshots_v2") }
                s.execute("reset role; set role anon")
                assertThrows(java.sql.SQLException::class.java) { s.executeQuery("select get_server_score_snapshot_v2('$day')") }
            }
        }
    }
}
