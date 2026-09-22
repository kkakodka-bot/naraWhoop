package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.SignalSampleReader
import com.noop.protocol.DeviceFamily
import com.noop.protocol.RrPacketProvenance
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset
import java.util.UUID

/** The byte fixture is projected through real PostgreSQL, dirtying, and the production reader. */
class RrPacketProvenanceIntegrationTest {
    private lateinit var db: PostgresClient
    private val user = UUID.randomUUID()
    private val device = UUID.randomUUID()
    private val packet = JSONObject(javaClass.getResource("/rr_packet_provenance_oracle.json")!!.readText())
        .getJSONArray("cases").getJSONObject(1).getString("hex")
        .let { RrPacketProvenance.checked(RrPacketProvenance.bytes(it)!!)!! }
    private val day = Instant.ofEpochSecond(packet.ts).atZone(ZoneOffset.UTC).toLocalDate().toString()

    @Before fun setup() {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run the disposable PostgreSQL harness", url != null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db = PostgresClient(url)
        resetFleetTestState(db)
        sql("insert into auth.users values ('$user')")
        sql("insert into profiles(id,timezone) values ('$user','UTC')")
        sql("insert into devices(id,user_id,device_family) values ('$device','$user','whoop5')")
    }

    @After fun close() { if (::db.isInitialized) db.close() }

    @Test fun missingProfilePreservesOwnedWhoop4FirmwareAndDefaultContext() {
        sql("delete from profiles where id='$user'")
        sql("delete from scoring_timezone_history where user_id='$user'")
        sql("update devices set device_family='whoop4',firmware='whoop4-test-firmware' where id='$device'")

        val reader = SignalSampleReader(db)
        val input = reader.loadDay(user, day, device)!!
        assertEquals(DeviceFamily.WHOOP4, input.deviceFamily)
        assertEquals("whoop4-test-firmware", input.deviceFirmware)
        assertEquals(30.0, input.profile.age, 0.0)
        assertEquals("nonbinary", input.profile.sex)
        assertEquals(70.0, input.profile.weightKg, 0.0)
        assertEquals(170.0, input.profile.heightCm, 0.0)
        assertEquals(0L, input.tzOffsetSeconds)
        assertEquals(listOf("UTC"), input.calendarOwnership!!.timezoneIds)

        val otherOwner = UUID.randomUUID()
        sql("insert into auth.users values ('$otherOwner')")
        sql("insert into profiles(id,timezone) values ('$otherOwner','Pacific/Honolulu')")
        assertNull(reader.loadDay(otherOwner, day, device))
        assertNull(reader.loadDay(otherOwner, day, device, "UTC"))
        assertNull(reader.loadDay(user, day, UUID.randomUUID()))
    }

    @Test fun packetOnlyArrivalRetainsZeroSlotIsOwnerScopedAndDirtiesTransactionally() {
        val insert = """
            insert into noop_rr_packet_provenance
            (user_id,device_id,"packetId",ts,"sensorTs","recordIndex","rawHex","srcChannel",
             "schemaVersion","decoderVersion","clockVersion","timestampPrecisionSeconds","clockOffsetSeconds","declaredCount")
            values('$user','$device','${packet.packetId}',${packet.ts},${packet.sensorTs},${packet.recordIndex},
              '${packet.rawHex}',5,1,'${packet.decoderVersion}','${packet.clockVersion}',1,0,3)
            on conflict do nothing
        """.trimIndent()
        db.withConnection { conn ->
            conn.autoCommit = false
            conn.createStatement().use { it.execute(insert) }
            assertEquals(0L, revision())
            conn.commit()
        }
        assertEquals(1L, revision())
        sql(insert)
        assertEquals(1L, revision())
        sql("update noop_rr_packet_provenance set ingested_at=clock_timestamp() where user_id='$user'")
        assertEquals(1L, revision())
        val reader = SignalSampleReader(db)
        val inputs = reader.loadDay(user,day,device,"UTC")!!
        assertTrue(inputs.rr.isEmpty())
        val observations = inputs.hrvObservations!!
        assertEquals(listOf(0,1,2), observations.map { it.ordinal })
        assertEquals(listOf(1000.0,0.0,500.0), observations.map { it.originalRRMs })
        assertTrue(observations.all { it.verifiedSpan == null && it.deviceFirmware == null })
        assertEquals("verified_packet_local_original_words_no_beat_clock", inputs.rrContinuityEvidence)
        assertNull(reader.loadDay(UUID.randomUUID(),day,device,"UTC"))

        // SQL shape acceptance is not cryptographic proof: the production reader checks the bytes.
        sql("update noop_rr_packet_provenance set \"rawHex\"=repeat('0',length(\"rawHex\")) where user_id='$user'")
        assertEquals(2L, revision())
        assertNull(reader.loadDay(user,day,device,"UTC")!!.hrvObservations)
        sql("delete from noop_rr_packet_provenance where user_id='$user'")
        assertEquals(3L, revision())
    }

    private fun sql(statement: String) = db.withConnection { c -> c.createStatement().use { it.execute(statement) } }
    private fun revision(): Long = db.withConnection { c -> c.createStatement().use { s ->
        s.executeQuery("select coalesce(max(input_revision),0) from physiology_work_items where user_id='$user' and day='$day'")
            .use { it.next(); it.getLong(1) }
    } }
}
