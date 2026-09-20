package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringWorkQueue
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.sql.SQLException
import java.util.UUID

class StandardHRReceiptIntegrationTest {
    private lateinit var db: PostgresClient
    private val user = UUID.randomUUID()
    private val other = UUID.randomUUID()
    private val device = UUID.randomUUID()
    private val session = UUID.randomUUID()

    @Before fun setup() {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run the disposable PostgreSQL harness", url != null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db = PostgresClient(url)
        sql("insert into auth.users values ('$user'),('$other')")
        sql("insert into profiles(id,timezone) values ('$user','UTC'),('$other','UTC')")
        sql("insert into devices(id,user_id) values ('$device','$user')")
    }

    @After fun close() { if (::db.isInitialized) db.close() }

    private fun receipt(ordinal: Int, owner: UUID = user) = """
        insert into noop_standard_hr_receipts(user_id,device_id,"receiptId",ts,"sessionId","notificationOrdinal",
          "receivedUnixMs","receivedMonotonicNs","rawHex","schemaVersion","clockVersion")
        values('$owner','$device','$session:$ordinal',1700000000,'$session',$ordinal,
          1700000000123,9007199254740993,'103c0004',1,'host-arrival-unmapped') on conflict do nothing
    """.trimIndent()

    @Test fun sameSecondReceiptsRemainDistinctExactAndDirtiedOnlyAfterCommit() {
        db.withConnection { connection ->
            connection.autoCommit = false
            connection.createStatement().use { it.execute(receipt(0)); it.execute(receipt(1)) }
            assertEquals(0L, count("physiology_work_items"))
            connection.commit()
        }
        assertEquals(2L, count("noop_standard_hr_receipts"))
        assertTrue(count("physiology_work_items") > 0)
        sql(receipt(0))
        assertEquals(2L, count("noop_standard_hr_receipts"))
        db.withConnection { c -> c.createStatement().use { s ->
            s.executeQuery("select \"receivedMonotonicNs\",\"clockVersion\" from noop_standard_hr_receipts where user_id='$user'").use {
                assertTrue(it.next()); assertEquals(9007199254740993L, it.getLong(1)); assertEquals("host-arrival-unmapped", it.getString(2))
            }
        } }
    }

    @Test fun ownershipAndRlsPreventCrossAccountAccessOrWrites() {
        sql(receipt(0))
        val foreignOwner = assertThrows(SQLException::class.java) { sql(receipt(1, other)) }
        assertEquals("23503", foreignOwner.sqlState)
        db.withConnection { c -> c.createStatement().use { s ->
            s.execute("set role authenticated")
            try {
                for ((owner, expected) in listOf(other to 0L, user to 1L)) {
                    s.execute("select set_config('request.jwt.claim.sub','$owner',false)")
                    s.executeQuery("select count(*) from noop_standard_hr_receipts").use { it.next(); assertEquals(expected, it.getLong(1)) }
                }
                assertEquals("42501", assertThrows(SQLException::class.java) { s.execute(receipt(2)) }.sqlState)
            } finally {
                s.execute("reset role"); s.execute("select set_config('request.jwt.claim.sub','',false)")
            }
        } }
    }

    @Test fun lateReceiptRevokesOldRevisionAndCannotReleaseTheReplacementLease() {
        val queue = ScoringWorkQueue(db)
        val day = "2023-11-14" // UTC day of the serialized receipt fixture.
        queue.dirtyWorkItem(user, device, day)
        sql("update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='$user'")
        val old = queue.claimOne(user, device, day)!!
        sql(receipt(0))
        assertFalse(queue.markDone(old, 1))
        sql("update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='$user'")
        val replacement = queue.claimOne(user, device, day)!!
        assertTrue(replacement.inputRevision > old.inputRevision)
        assertFalse(queue.renew(old))
        assertFalse(queue.markDone(old, 1))
        assertTrue(queue.renew(replacement))
    }

    @Test fun repairMigrationRevokesPreexistingCoalescedLateInputClaim() {
        db.withConnection { c -> c.createStatement().use { s ->
            s.executeQuery("select input_revision,status,lease_token is null and run_id is null as revoked " +
                "from physiology_work_items where user_id='a8880000-0000-4000-8000-000000000101'").use {
                assertTrue(it.next()); assertEquals(2L,it.getLong(1)); assertEquals("pending",it.getString(2)); assertTrue(it.getBoolean(3))
            }
            val failure = assertThrows(SQLException::class.java) { s.execute("select scoring_begin_publication(" +
                "user_id,device_id,day,input_revision,lease_token,run_id) from queue_test_coalesced_claim") }
            assertEquals("40001", failure.sqlState)
        } }
    }

    @Test fun receiverUpsertAcceptsIdenticalReplayButRetainsFirstConflictingEvidence() {
        sql(receipt(0))
        val upsert = receipt(0).replace("on conflict do nothing", "on conflict(user_id,device_id,\"receiptId\") do update set " +
            "\"rawHex\"=excluded.\"rawHex\",\"receivedUnixMs\"=excluded.\"receivedUnixMs\",ingested_at=clock_timestamp()")
        sql(upsert)
        val conflict = assertThrows(SQLException::class.java) { sql(upsert.replace("'103c0004'", "'103c0002'")) }
        assertEquals("23514",conflict.sqlState)
        db.withConnection { c -> c.createStatement().use { s ->
            s.executeQuery("select \"rawHex\" from noop_standard_hr_receipts where user_id='$user'").use {
                assertTrue(it.next()); assertEquals("103c0004",it.getString(1)); assertFalse(it.next())
            }
        } }
    }

    @Test fun continuousArrivalDuringEveryRunStaysPendingInsteadOfPublishingStale() {
        val queue = ScoringWorkQueue(db)
        val day = "2023-11-14"
        queue.dirtyWorkItem(user,device,day)
        var completed = 0
        repeat(20) { ordinal ->
            sql("update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='$user'")
            val item = queue.claimOne(user,device,day)!!
            sql(receipt(ordinal))
            if (queue.markDone(item,1)) completed++
        }
        // Known liveness boundary: safe fencing is not a five-minute publication guarantee.
        // Every run in this counterexample receives newer input before completion.
        assertEquals(0,completed)
        db.withConnection { c -> c.createStatement().use { s ->
            s.executeQuery("select status,done_at is null from physiology_work_items where user_id='$user' and day='$day'").use {
                assertTrue(it.next()); assertEquals("pending",it.getString(1)); assertTrue(it.getBoolean(2))
            }
        } }
    }

    private fun sql(statement: String) = db.withConnection { c -> c.createStatement().use { it.execute(statement) } }
    private fun count(table: String) = db.withConnection { c -> c.createStatement().use { s ->
        s.executeQuery("select count(*) from $table where user_id='$user'").use { it.next(); it.getLong(1) }
    } }
}
