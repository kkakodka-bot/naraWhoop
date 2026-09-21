package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringInputGate
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Path
import java.sql.Connection
import java.sql.SQLException
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.UUID

/** Real thermal projection writes, fencing, and migration over retained immutable snapshots. */
class SkinTemperatureDependencyIntegrationTest {
    private lateinit var db: PostgresClient
    private val user = UUID.randomUUID()
    private val otherUser = UUID.randomUUID()
    private val device = UUID.randomUUID()
    private val otherDevice = UUID.randomUUID()
    private val day = LocalDate.of(2026, 7, 10)
    private val ts = day.atTime(23, 59).toEpochSecond(ZoneOffset.UTC)

    @Before fun setup() {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh", url != null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db = PostgresClient(url)
        sql("insert into auth.users values('$user'),('$otherUser')")
        sql("insert into profiles(id,timezone) values('$user','UTC'),('$otherUser','UTC')")
        sql("insert into devices(id,user_id) values('$device','$user'),('$otherDevice','$otherUser')")
    }

    @After fun close() { if (::db.isInitialized) db.close() }

    @Test fun insertCorrectionsAndDeleteInvalidateBothDependentDaysAndVersions() {
        sql(sample())
        for (table in listOf("physiology_work_items", "scoring_work_items")) {
            assertEquals(1L, revision(table = table))
            assertEquals(1L, revision(date = day.plusDays(1), table = table))
        }
        sql("update noop_skin_temp_samples set raw=3500,\"aux1Raw\"=340 where user_id='$user'")
        assertEquals(2L, revision())
        sql("delete from noop_skin_temp_samples where user_id='$user'")
        assertEquals(3L, revision())
        assertEquals(3L, revision(date = day.plusDays(1)))
        assertEquals(0L, revision(otherUser, otherDevice))
    }

    @Test fun semanticNoopAndDuplicateReplayDoNotCreateWork() {
        sql(sample())
        sql(sample() + " on conflict(user_id,device_id,ts) do nothing")
        sql(sample() + " on conflict(user_id,device_id,ts) do update set raw=excluded.raw," +
            "batch_id=excluded.batch_id,ingested_at=clock_timestamp()")
        sql("update noop_skin_temp_samples set raw=raw,ingested_at=clock_timestamp() where user_id='$user'")
        assertEquals(1L, revision())
        assertEquals(1L, revision(table = "scoring_work_items"))
        assertEquals(1L, number("select count(*) from noop_skin_temp_samples where user_id='$user'"))
    }

    @Test fun movedRecordInvalidatesOldAndNewOwnerDeviceAndDaysOnly() {
        sql(sample())
        val movedTs = ts + 7 * 86400
        sql("update noop_skin_temp_samples set user_id='$otherUser',device_id='$otherDevice',ts=$movedTs where user_id='$user'")
        for (offset in listOf(0L, 1L)) {
            assertEquals(2L, revision(date = day.plusDays(offset)))
            assertEquals(1L, revision(otherUser, otherDevice, day.plusDays(7 + offset)))
        }
        assertEquals(0L, revision(date = day.plusDays(7)))
        assertEquals(0L, revision(otherUser, otherDevice))
    }

    @Test fun inputAndRevisionCommitOrRollbackTogether() {
        db.withConnection { connection ->
            connection.autoCommit = false
            try {
                execute(connection, sample())
                assertEquals(1L, revision(connection = connection))
                assertEquals(0L, revision())
                connection.rollback()
                assertEquals(0L, revision())
                assertEquals(0L, number("select count(*) from noop_skin_temp_samples where user_id='$user'"))
                execute(connection, sample())
                connection.commit()
            } finally { connection.rollback(); connection.autoCommit = true }
        }
        assertEquals(1L, revision())
    }

    @Test fun inputGateRejectsChangedThermalWritesAtomicallyButOtherOwnersProceed() {
        sql(sample())
        ScoringInputGate(db).withGate(user, device) {
            failure("55P03") { sql(sample(at = ts + 1)) }
            failure("55P03") { sql("update noop_skin_temp_samples set raw=3500 where user_id='$user'") }
            failure("55P03") { sql("delete from noop_skin_temp_samples where user_id='$user'") }
            sql("update noop_skin_temp_samples set ingested_at=clock_timestamp() where user_id='$user'")
            sql(sample(otherUser, otherDevice))
            assertEquals(1L, revision())
            assertEquals(3400L, number("select raw from noop_skin_temp_samples where user_id='$user'"))
            assertEquals(1L, revision(otherUser, otherDevice))
        }
        sql("update noop_skin_temp_samples set raw=3500 where user_id='$user'")
        assertEquals(2L, revision())
    }

    @Test fun migrationRequeuesEachPublishedV2DayOnceWithoutChangingInputsOrSnapshots() {
        db.withConnection { connection ->
            connection.autoCommit = false
            try {
                dropTriggers(connection) // Simulate the schema immediately before this migration.
                execute(connection, sample())
                execute(connection, "delete from noop_skin_temp_samples where user_id='$user'")
                execute(connection, "select physiology_enqueue_day('$user','$device','$day','America/Los_Angeles',0)")
                execute(connection, "select physiology_enqueue_day('$otherUser','$otherDevice','$day','UTC',0)")
                execute(connection, snapshot(user, device, day, 1))
                execute(connection, "select physiology_enqueue_day('$user','$device','$day','America/Los_Angeles',0)")
                execute(connection, snapshot(user, device, day, 2))
                execute(connection, snapshot(otherUser, otherDevice, day, 1))
                execute(connection, "select scoring_enqueue_legacy('$user','$device','${day.plusDays(3)}','UTC')")
                execute(connection, snapshot(user, device, day.plusDays(3), 1, "frwhoop-server-1"))
                val before = number(connection, "select count(*) from server_physiology_results")
                execute(connection, migrationBody())
                assertEquals(3L, revision(connection = connection))
                assertEquals(2L, revision(otherUser, otherDevice, connection = connection))
                assertEquals(0L, revision(date = day.plusDays(3), connection = connection))
                assertEquals(before, number(connection, "select count(*) from server_physiology_results"))
                assertEquals(0L, number(connection, "select count(*) from noop_skin_temp_samples where user_id='$user'"))
                assertEquals(1L, number(connection, "select count(*) from physiology_work_items where user_id='$user' and day='$day' and timezone_id='America/Los_Angeles'"))
                assertEquals(3L, triggerCount(connection))
            } finally { connection.rollback(); connection.autoCommit = true }
        }
    }

    @Test fun applyingMigrationTwiceFailsAtomicallyBeforeAnotherCatchup() {
        sql(sample())
        db.withConnection { connection ->
            connection.autoCommit = false
            try { failure("42710") { execute(connection, migrationBody()) } }
            finally { connection.rollback(); connection.autoCommit = true }
            assertEquals(3L, triggerCount(connection))
        }
        assertEquals(1L, revision())
        assertEquals(1L, number("select count(*) from noop_skin_temp_samples where user_id='$user'"))
    }

    @Test fun oversizedMigrationCatchupAbortsBeforeInstallingTriggersOrChangingWork() {
        sql(sample())
        db.withConnection { connection ->
            connection.autoCommit = false
            try {
                dropTriggers(connection)
                execute(connection, "set local statement_timeout='30s'")
                execute(connection, "create temp table thermal_fixture_devices(id uuid primary key) on commit drop")
                execute(connection, "insert into thermal_fixture_devices select gen_random_uuid() from generate_series(1,10001)")
                execute(connection, "insert into devices(id,user_id) select id,'$user' from thermal_fixture_devices")
                execute(connection, """insert into physiology_work_items(user_id,device_id,day,timezone_id)
                    select '$user',id,'$day','UTC' from thermal_fixture_devices""")
                execute(connection, """insert into server_physiology_results
                    (user_id,device_id,period_day,algorithm_version,input_revision,run_id,manifest_hash,payload,payload_hash,computed_at,publication_status)
                    select '$user',id,'$day','frwhoop-physiology-2',1,gen_random_uuid(),repeat('a',64),'{}',repeat('b',64),now(),'provisional'
                    from thermal_fixture_devices""")
                val checkpoint = connection.setSavepoint()
                failure("54000") { execute(connection, migrationBody()) }
                connection.rollback(checkpoint)
                assertEquals(0L, triggerCount(connection))
                assertEquals(1L, revision(connection = connection))
            } finally { connection.rollback(); connection.autoCommit = true }
            assertEquals(3L, triggerCount(connection))
        }
        assertEquals(1L, revision())
    }

    private fun sample(owner: UUID = user, strap: UUID = device, at: Long = ts) =
        "insert into noop_skin_temp_samples(user_id,device_id,source_id,ts,raw,batch_id) " +
            "values('$owner','$strap','${UUID.randomUUID()}',$at,3400,'${UUID.randomUUID()}')"
    private fun snapshot(owner: UUID, strap: UUID, date: LocalDate, revision: Int, version: String = "frwhoop-physiology-2") =
        "insert into server_physiology_results(user_id,device_id,period_day,algorithm_version,input_revision,run_id,manifest_hash,payload,payload_hash,computed_at,publication_status) " +
            "values('$owner','$strap','$date','$version',$revision,'${UUID.randomUUID()}',repeat('a',64),'{}',repeat('b',64),now(),'provisional')"
    private fun migrationBody(): String {
        val relative = "supabase/migrations/20260919010000_skin_temperature_dependencies.sql"
        val path = listOf(Path.of("../..", relative), Path.of("..", relative)).first(Files::exists)
        return Files.readString(path).lineSequence().filter { it.trim() !in setOf("begin;", "commit;") }.joinToString("\n")
    }
    private fun dropTriggers(connection: Connection) {
        for (operation in listOf("insert", "update", "delete")) execute(connection,
            "drop trigger scoring_dirty_$operation on noop_skin_temp_samples")
    }
    private fun triggerCount(connection: Connection): Long {
        assertEquals("Thermal repair must retain all historical invalidation triggers", 3L, number(connection,
            "select count(*) from pg_trigger where tgrelid='noop_skin_temp_samples'::regclass and not tgisinternal " +
                "and tgname in ('scoring_insert_v2','scoring_update_v2','scoring_delete_v2')"))
        return number(connection,
            "select count(*) from pg_trigger where tgrelid='noop_skin_temp_samples'::regclass and not tgisinternal " +
                "and tgname in ('scoring_dirty_insert','scoring_dirty_update','scoring_dirty_delete')")
    }
    private fun failure(state: String, operation: () -> Unit) {
        try { operation(); fail("Expected SQLSTATE $state") }
        catch (error: SQLException) { assertEquals(state, error.sqlState) }
    }
    private fun execute(connection: Connection, statement: String) { connection.createStatement().use { it.execute(statement) } }
    private fun sql(statement: String) = db.withConnection { execute(it, statement) }
    private fun revision(owner: UUID = user, strap: UUID = device, date: LocalDate = day,
                         table: String = "physiology_work_items", connection: Connection? = null): Long {
        val query = "select coalesce(max(input_revision),0) from $table where user_id='$owner' and device_id='$strap' and day='$date'"
        return if (connection == null) number(query) else number(connection, query)
    }
    private fun number(statement: String) = db.withConnection { number(it, statement) }
    private fun number(connection: Connection, statement: String): Long = connection.createStatement().use { query ->
        query.executeQuery(statement).use { it.next(); it.getLong(1) }
    }
}
