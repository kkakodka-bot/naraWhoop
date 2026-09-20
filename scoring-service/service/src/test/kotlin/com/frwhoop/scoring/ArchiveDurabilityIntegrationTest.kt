package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.derived.SnapshotArchiveWorker
import org.junit.Assert.*
import org.junit.Test

class ArchiveDurabilityIntegrationTest : PgIntegrationBase() {
    private fun worker(fail: Boolean = false, captured: MutableList<Pair<String,ByteArray>> = mutableListOf()) =
        SnapshotArchiveWorker(pg.db, object : B2ObjectStore.PutClient {
            override fun putObject(key: String,body: ByteArray,contentType: String): B2ObjectStore.PutResult {
                captured.add(key to body.copyOf())
                if (fail) error("injected_put_failure")
                return B2ObjectStore.PutResult("fixture-etag",body.size)
            }
        },"disposable-test-bucket")

    @Test fun failedArchiveSurvivesWithoutNewScoreAndRetriesExactCommittedBytes() {
        queue.dirtyWorkItem(u,device,day); queue.publish(queue.claim()!!,payload(),1)
        val captured=mutableListOf<Pair<String,ByteArray>>()
        assertTrue(worker(true,captured).runOne())
        assertNull(queue.claim())
        assertEquals("1",scalar("select consecutive_failures from scoring_archive_jobs_v2"))
        sql("update scoring_archive_jobs_v2 set not_before=clock_timestamp()-interval '1 second'")
        assertTrue(worker(false,captured).runOne())
        assertEquals(captured[0].first,captured[1].first)
        assertArrayEquals(captured[0].second,captured[1].second)
        assertEquals("1",scalar("select count(*) from object_manifests where status='ready'"))
        assertFalse(worker().runOne())
    }

    @Test fun uploadThenCrashAndLeaseReclaimPreservesKeyAndFencesManifestSettlement() {
        queue.dirtyWorkItem(u,device,day); queue.publish(queue.claim()!!,payload(),1)
        val w=worker(); val old=w.claim()!!
        assertTrue(w.renew(old))
        sql("update scoring_archive_jobs_v2 set lease_until=clock_timestamp()-interval '1 second'")
        val next=worker().claim()!!
        assertEquals(old.key,next.key); assertArrayEquals(old.bytes,next.bytes)
        assertFalse(w.complete(old)); assertFalse(w.fail(old,"late")); assertFalse(w.renew(old))
        assertTrue(w.complete(next)); assertFalse(w.complete(next))
    }

    @Test fun manifestFailureRollsBackArchiveCompletionAndDoesNotRescore() {
        queue.dirtyWorkItem(u,device,day); queue.publish(queue.claim()!!,payload(),1)
        val w=worker(); val job=w.claim()!!
        sql("""insert into object_manifests(user_id,device_id,object_kind,object_key,sha256,compressed_bytes)
            values('$u','$device','derived_scores','${job.key}','wrong',1)""")
        assertThrows(java.sql.SQLException::class.java) { w.complete(job) }
        assertEquals("0",scalar("select count(*) from scoring_archive_jobs_v2 where completed_at is not null"))
        assertNull(queue.claim())
        sql("delete from object_manifests")
        assertTrue(w.complete(job))
    }

    @Test fun differentDevicesAndRevisionsNeverReuseArchiveIdentity() {
        repeat(2) {
            queue.dirtyWorkItem(u,device,day); queue.publish(queue.claim()!!,payload(),1)
            queue.dirtyWorkItem(u,device2,day); queue.publish(queue.claim()!!,payload(),1)
        }
        assertEquals("4",scalar("select count(distinct object_key) from scoring_archive_jobs_v2"))
        repeat(4) { assertTrue(worker().runOne()) }
        assertEquals("4",scalar("select count(*) from object_manifests"))
    }

    @Test fun archiveDeadLetterCanBeRepairedWithoutRecomputingOrNewPhoneUpload() {
        queue.dirtyWorkItem(u,device,day)
        val revision=queue.publish(queue.claim()!!,payload(),1)!!
        val captured=mutableListOf<Pair<String,ByteArray>>()
        repeat(12) {
            assertTrue(worker(true,captured).runOne())
            assertFalse(worker().runOne())
            sql("update scoring_archive_jobs_v2 set not_before=clock_timestamp()-interval '1 second'")
        }
        assertEquals("t",scalar("select dead_letter from scoring_archive_jobs_v2"))
        assertFalse(worker().runOne())
        assertEquals("t",scalar("select retry_scoring_archive_v2($revision)"))
        assertTrue(worker(false,captured).runOne())
        assertArrayEquals(captured.first().second,captured.last().second)
        assertEquals("1",scalar("select success_count from scoring_jobs_v2"))
        assertEquals("f",scalar("select retry_scoring_archive_v2($revision)"))
    }

    @Test fun manifestReceiptMustMatchCommittedSnapshotBytes() {
        queue.dirtyWorkItem(u,device,day); queue.publish(queue.claim()!!,payload(),1)
        val w=worker(); val job=w.claim()!!
        assertThrows(java.sql.SQLException::class.java) {
            w.complete(job.copy(bytes="not the committed payload".toByteArray()))
        }
        assertEquals("0",scalar("select count(*) from object_manifests"))
        assertTrue(w.complete(job))
    }
}
