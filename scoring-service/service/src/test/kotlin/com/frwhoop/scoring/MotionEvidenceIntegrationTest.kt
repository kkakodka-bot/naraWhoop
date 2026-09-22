package com.frwhoop.scoring

import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.SignalSampleReader
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.sql.SQLException
import java.time.Instant
import java.util.UUID

class MotionEvidenceIntegrationTest {
    private lateinit var db:PostgresClient
    private val user=UUID.randomUUID(); private val device=UUID.randomUUID()
    private val start=Instant.parse("2026-09-17T01:00:00Z").epochSecond
    private val proof="projected-dynamic-acceleration-g-1"
    private val orientationProof="projected-gravity-g-1"

    @Before fun setup() {
        val url=System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run disposable PostgreSQL harness",url!=null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db=PostgresClient(url)
        resetFleetTestState(db)
        sql("insert into auth.users values('$user')")
        sql("insert into profiles(id,timezone) values('$user','UTC')")
        sql("insert into devices(id,user_id) values('$device','$user')")
    }
    @After fun close() { if(::db.isInitialized) db.close() }

    @Test fun legacyStoredZerosAndValuesRemainEvidenceUnavailableWhileQualifiedZeroSurvives() {
        row(start,"0",null);row(start+1,"0.4",null);row(start+2,"null",null)
        row(start+3,"0",proof);row(start+4,"0.04",proof)
        val rows=SignalSampleReader(db).loadDay(user,"2026-09-17",device)!!.gravity.associateBy { it.ts }
        for (time in start..start+2) assertNull(rows.getValue(time).dynAccel)
        assertEquals(0.0,rows.getValue(start+3).dynAccel!!,0.0)
        assertEquals(0.04,rows.getValue(start+4).dynAccel!!,0.0)
        assertEquals(2L,number("select count(*) from noop_gravity_samples where user_id='$user' and motion_evidence_version is null and \"dynAccel\" is not null"))
    }

    @Test fun historicalPlausibleCoercedOrientationIsUnavailableAndNewOrientationOnlyRowsSurvive() {
        row(start,"0",null,orientation=null)
        row(start+1,"null",null)
        val rows=SignalSampleReader(db).loadDay(user,"2026-09-17",device)!!.gravity
        assertEquals(listOf(start+1),rows.map { it.ts })
        assertEquals(1.0,rows.single().z,0.0)
        assertNull(rows.single().dynAccel)
        assertEquals(2L,number("select count(*) from noop_gravity_samples where user_id='$user' and x=0 and y=0 and z=1"))
        val before=revision()
        // Test-only operator attestation models verified raw-source reprocessing;
        // production migration must never derive this proof from scalar columns.
        sql("update noop_gravity_samples set orientation_evidence_version='$orientationProof' where user_id='$user' and ts=$start")
        assertTrue(revision()>before)
        assertEquals(2,SignalSampleReader(db).loadDay(user,"2026-09-17",device)!!.gravity.size)
    }

    @Test fun proofAdditionAndRemovalInvalidateInputRevisionWithoutChangingStoredScalar() {
        row(start,"0",null)
        val before=revision()
        sql("update noop_gravity_samples set motion_evidence_version='$proof' where user_id='$user'")
        assertTrue(revision()>before)
        assertEquals(0.0,SignalSampleReader(db).loadDay(user,"2026-09-17",device)!!.gravity.single().dynAccel!!,0.0)
        val qualified=revision()
        sql("update noop_gravity_samples set motion_evidence_version=null where user_id='$user'")
        assertTrue(revision()>qualified)
        assertNull(SignalSampleReader(db).loadDay(user,"2026-09-17",device)!!.gravity.single().dynAccel)
        assertEquals(1L,number("select count(*) from noop_gravity_samples where user_id='$user' and \"dynAccel\"=0"))
    }

    @Test fun unknownProofAndImpossibleQualifiedDynamicAccelerationAreRejected() {
        for ((value,version) in listOf("null" to proof,"-0.1" to proof,"8.1" to proof,"'NaN'" to proof,"0" to "unreviewed")) {
            try { row(start,value,version);fail("Expected invalid proof rejection") }
            catch(error:SQLException) { assertEquals("23514",error.sqlState) }
        }
        try { row(start,"0",proof,orientation=null);fail("Motion proof requires this receiver's verified orientation/timestamp") }
        catch(error:SQLException) { assertEquals("23514",error.sqlState) }
        try { row(start,"null",null,orientation="unreviewed");fail("Unknown orientation proof") }
        catch(error:SQLException) { assertEquals("23514",error.sqlState) }
    }

    private fun row(ts:Long,value:String,version:String?,orientation:String?=orientationProof)=sql("insert into noop_gravity_samples("+
        "user_id,device_id,source_id,ts,x,y,z,\"dynAccel\",motion_evidence_version,orientation_evidence_version,batch_id) values("+
        "'$user','$device','${UUID.randomUUID()}',$ts,0,0,1,$value,${version?.let { "'$it'" } ?: "null"},${orientation?.let { "'$it'" } ?: "null"},'${UUID.randomUUID()}')")
    private fun revision()=number("select input_revision from physiology_work_items where user_id='$user' and device_id='$device' and day='2026-09-17'")
    private fun sql(value:String)=db.withConnection { c -> c.createStatement().use { it.execute(value) } }
    private fun number(value:String)=db.withConnection { c -> c.createStatement().use { s -> s.executeQuery(value).use { r -> r.next();r.getLong(1) } } }
}
