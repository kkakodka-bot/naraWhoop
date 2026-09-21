package com.frwhoop.scoring

import com.frwhoop.scoring.db.HistoricalScoringWorkQueue
import com.frwhoop.scoring.db.HistoricalSignalSampleReader
import com.frwhoop.scoring.health.HeartbeatReporter
import com.frwhoop.scoring.health.WorkerHeartbeatIdentity
import com.frwhoop.scoring.scoring.HistoricalScoringPoller
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class HistoricalScoringPollerIntegrationTest : PgIntegrationBase() {
    @Test fun productionPollerInvokesAllOrchestratorsAndPublishesOwnerDeviceBoundShadows() {
        val peerDevice = UUID.randomUUID()
        sql("insert into devices(id,user_id,source_kind,device_family) values('$peerDevice','$other','noop_push','whoop5')")
        val at = java.time.Instant.parse("2026-09-15T12:00:00Z").epochSecond
        sql("""insert into noop_hr_samples(user_id,device_id,source_id,ts,bpm,batch_id) values
            ('$u','$device',gen_random_uuid(),$at,61,gen_random_uuid()),
            ('$other','$peerDevice',gen_random_uuid(),$at,87,gen_random_uuid())""")
        val queue = HistoricalScoringWorkQueue(pg.db, HistoricalScoringPoller.VERSION)
        val identity = WorkerHeartbeatIdentity(UUID.randomUUID(), "a".repeat(40))
        val heartbeat = HeartbeatReporter(pg.db, queue.algorithmVersion, identity)
        val poller = HistoricalScoringPoller(pg.db, queue, HistoricalSignalSampleReader(pg.db), heartbeat)
        var published = 0
        repeat(5) { published += poller.pollOnce() }
        assertTrue(published >= 2)
        for ((owner, deviceId, expected) in listOf(Triple(u, device, 61.0), Triple(other, peerDevice, 87.0))) {
            val result = JSONObject(scalar("""select payload::text from scoring_snapshots_v2
                where user_id='$owner' and device_id='$deviceId' and day='$day'
                and algorithm_version='${queue.algorithmVersion}' order by result_revision desc limit 1""")!!)
            assertEquals(expected, result.getJSONObject("metrics").getJSONObject("avg_hr").getDouble("value"), 0.0)
            assertTrue(result.getJSONObject("details").has("day_cycle"))
            assertTrue(result.getJSONObject("details").has("illness"))
            assertTrue(result.getJSONObject("details").has("workouts"))
            assertTrue(result.getJSONObject("coverage").getBoolean("historicalStateAvailable"))
            assertEquals("shadow", result.getString("publicationMode"))
            assertFalse(result.getBoolean("canonicalOutputsAllowed"))
            assertTrue(result.getJSONObject("metrics").getJSONObject("spo2_pct").isNull("value"))
            assertTrue(result.getJSONObject("metrics").getJSONObject("hrv_rmssd_ms").isNull("value"))
        }
        assertEquals("0", scalar("""select count(*) from scoring_snapshots_v2 s
            join devices d on d.id=s.device_id where d.user_id<>s.user_id"""))
        assertEquals("1", scalar("""select count(*) from physiology_worker_heartbeats
            where process_instance_id='${identity.processInstanceId}' and last_poll_at is not null
            and last_score_at is not null and algorithm_version='${queue.algorithmVersion}'"""))
        assertEquals(published.toString(), scalar("select count(*) from scoring_history_checkpoints_v3"))
    }
}
