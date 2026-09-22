package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient

/** This serial fixture suite shares one disposable database. Abandoned work from a completed test
 * must not consume the next test's fleet quota. Claims within each test retain production limits. */
fun resetFleetTestState(db: PostgresClient) {
    require(System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")?.let {
        it.contains("@127.0.0.1:") && it.endsWith("/physiology_queue_test")
    } == true)
    db.withConnection { c -> c.createStatement().use { s ->
        s.execute("delete from scoring_fleet_reservations")
        s.execute("update scoring_fleet_policy set max_workers=4,per_user=2,per_device=2,live_weight=3")
        s.execute("update noop_fleet_intake_policy set model_slots=1,history_slots=1")
        s.execute("update physiology_model_work_items set lease_expires_at=clock_timestamp()-interval '1 second' where state='running'")
    } }
}
