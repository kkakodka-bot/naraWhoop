package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.sql.Connection
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.UUID

/** Actual transition-table triggers, including the multi-device bulk-ingest timeout workload. */
class ProjectionInvalidationIntegrationTest {
    private lateinit var db: PostgresClient
    private val user = UUID.randomUUID()
    private val otherUser = UUID.randomUUID()
    private val device = UUID.randomUUID()
    private val otherDevice = UUID.randomUUID()
    private val day = LocalDate.of(2026, 7, 10)
    private val ts = day.atTime(12, 0).toEpochSecond(ZoneOffset.UTC)

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

    @Test fun bulkPacketsAndMetadataOnlyReplayRemainBoundedWithManyDevices() {
        // Production had 28 registered devices. Stress a larger same-owner fleet so the old
        // repeated JSON serialization also exceeds its unchanged 8-second budget on a fast
        // development machine; unrelated owners exercise tenant exclusion independently.
        sql("insert into devices(id,user_id) select gen_random_uuid(),'$user' from generate_series(1,256)")
        sql("insert into devices(id,user_id) select gen_random_uuid(),'$otherUser' from generate_series(1,28)")
        db.withConnection { c ->
            c.autoCommit = false
            try {
                c.createStatement().use {
                    it.execute("set local statement_timeout='8s'")
                    it.execute("set local work_mem='3500kB'")
                    it.execute("set local jit=off")
                }
                timed(c, "insert 5000 packet rows with 286 registered devices", packets(5000))
                assertEquals(1L, revision(c, user, device, day))
                timed(c, "replay 5000 packet rows with only arrival metadata changed", packets(5000))
                assertEquals(1L, revision(c, user, device, day))
                assertEquals(5000L, number(c, "select count(*) from noop_rr_packet_provenance where user_id='$user'"))
                assertEquals(0L, number(c, "select count(*) from physiology_work_items where user_id='$otherUser' or (user_id='$user' and device_id<>'$device')"))
                c.commit()
            } catch (error: Throwable) {
                c.rollback()
                throw error
            }
        }
    }

    @Test fun semanticChangesDirtyBothOriginalAndReplacementOwnerDeviceAndTime() {
        sql(packets(1))
        sql("update noop_rr_packet_provenance set \"declaredCount\"=2 where user_id='$user'")
        assertEquals(2L, revision(user, device, day))
        val replacementTs = ts + 7 * 86400
        sql("""update noop_rr_packet_provenance set user_id='$otherUser',device_id='$otherDevice',
            ts=$replacementTs,"sensorTs"=$replacementTs where user_id='$user'""")
        assertEquals(3L, revision(user, device, day))
        assertEquals(1L, revision(otherUser, otherDevice, day.plusDays(7)))
        assertEquals(0L, revision(user, device, day.plusDays(7)))
        assertEquals(0L, revision(otherUser, otherDevice, day))
        sql("delete from noop_rr_packet_provenance where user_id='$otherUser'")
        assertEquals(2L, revision(otherUser, otherDevice, day.plusDays(7)))
    }

    @Test fun deviceLessBoundaryEditStillInvalidatesAllOwnedDevicesAndBothSpans() {
        val secondDevice = UUID.randomUUID()
        val session = UUID.randomUUID()
        sql("insert into devices(id,user_id) values('$secondDevice','$user')")
        sql("""insert into sessions(id,user_id,start_at,end_at) values('$session','$user',
            '$day 23:50:00+00','${day.plusDays(1)} 00:10:00+00')""")
        for (owned in listOf(device, secondDevice)) {
            assertEquals(1L, revision(user, owned, day))
            assertEquals(1L, revision(user, owned, day.plusDays(1)))
        }
        sql("update sessions set updated_at=clock_timestamp() where id='$session'")
        assertEquals(1L, revision(user, device, day))
        sql("""update sessions set start_at='${day.plusDays(7)} 23:50:00+00',
            end_at='${day.plusDays(8)} 00:10:00+00' where id='$session'""")
        for (owned in listOf(device, secondDevice)) {
            assertEquals(2L, revision(user, owned, day))
            assertEquals(2L, revision(user, owned, day.plusDays(1)))
            assertEquals(1L, revision(user, owned, day.plusDays(7)))
            assertEquals(1L, revision(user, owned, day.plusDays(8)))
        }
        assertEquals(0L, revision(otherUser, otherDevice, day))
    }

    private fun packets(count: Int) = """
        insert into noop_rr_packet_provenance
          (user_id,device_id,"packetId",ts,"sensorTs","recordIndex","rawHex","srcChannel",
           "schemaVersion","decoderVersion","clockVersion","timestampPrecisionSeconds","clockOffsetSeconds","declaredCount",batch_id)
        select '$user','$device',lpad(to_hex(i),64,'0'),$ts+i,$ts+i,i,repeat('ab',124),5,
          1,'whoop5-v18-original-words-v1','sensor-second-unmapped',1,0,1,gen_random_uuid()
          from generate_series(1,$count) i
        on conflict(user_id,device_id,"packetId") do update set
          batch_id=excluded.batch_id,ingested_at=clock_timestamp()
    """.trimIndent()

    private fun timed(c: Connection, description: String, statement: String) {
        val start = System.nanoTime()
        c.createStatement().use { it.execute(statement) }
        println("Projection invalidation: $description: ${(System.nanoTime() - start) / 1_000_000} ms")
    }
    private fun sql(statement: String) = db.withConnection { c -> c.createStatement().use { it.execute(statement) } }
    private fun revision(owner: UUID, strap: UUID, date: LocalDate) = db.withConnection { revision(it, owner, strap, date) }
    private fun revision(c: Connection, owner: UUID, strap: UUID, date: LocalDate) = number(c,
        "select coalesce(max(input_revision),0) from physiology_work_items where user_id='$owner' and device_id='$strap' and day='$date'")
    private fun number(c: Connection, statement: String): Long = c.createStatement().use { s ->
        s.executeQuery(statement).use { it.next(); it.getLong(1) }
    }
}
