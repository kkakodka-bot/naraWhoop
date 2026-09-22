package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.db.PostgresClient
import com.frwhoop.scoring.db.ScoringWorkQueue
import com.frwhoop.scoring.db.SignalSampleReader
import com.frwhoop.scoring.scoring.CanonicalScorePayload
import com.frwhoop.scoring.scoring.DayScorer
import com.frwhoop.scoring.signals.BoundedRawFeatureLane
import com.frwhoop.scoring.signals.SensorAcquisitionProof
import com.noop.analytics.HrvWindow
import com.noop.protocol.RrPacketProvenance
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.sql.Connection
import java.sql.SQLException
import java.nio.file.Files
import java.nio.file.Path
import java.time.Instant
import java.util.Base64
import java.util.UUID

/** Synthetic byte captures through real PostgreSQL, production readers/scorer, and score RPCs.
 * No fixture is a device qualification, reference validation, or publication authorization.
 */
class SensorWindowIntegrationTest {
    private lateinit var db: PostgresClient
    private lateinit var queue: ScoringWorkQueue
    private val user = UUID.randomUUID()
    private val device = UUID.randomUUID()
    private val source = UUID.randomUUID()
    private val otherUser = UUID.randomUUID()
    private val otherDevice = UUID.randomUUID()
    private val start = SensorFixtures.start
    private val day = "2026-08-18"

    @Before fun setup() {
        val url = System.getenv("PHYSIOLOGY_TEST_DATABASE_URL")
        assumeTrue("Run scripts/test-physiology-queue.sh", url != null)
        require(url!!.contains("@127.0.0.1:") && url.endsWith("/physiology_queue_test"))
        db = PostgresClient(url)
        queue = ScoringWorkQueue(db)
        sql("insert into auth.users values ('$user'),('$otherUser')")
        sql("insert into profiles(id,timezone) values ('$user','UTC'),('$otherUser','UTC')")
        sql("insert into devices(id,user_id,device_family) values " +
            "('$device','$user','whoop5'),('$otherDevice','$otherUser','whoop5')")
        // The minimal disposable platform bootstrap intentionally lacks Supabase default grants.
        sql("grant usage on schema auth to authenticated,service_role")
        sql("grant select on devices,noop_hr_samples,server_daily_scores,server_sleep_nights to authenticated,service_role")
    }

    @After fun close() { if (::db.isInitialized) db.close() }

    @Test fun clientsAndWorkerCannotIssueReceiptsAndOwnerCannotReadAnotherOwnersResults() {
        val proof = owned(SensorFixtures.beats().second)
        for (role in listOf("authenticated", "service_role")) asRole(role, user) { connection ->
            expectFailure("42501") { insertReceipt(connection, proof) }
        }
        insertReceipt(proof)
        asRole("service_role", user) { connection ->
            assertEquals(1L, number(connection, "select count(*) from sensor_acquisition_contracts where user_id='$user'"))
            expectFailure("42501") { connection.createStatement().use {
                it.execute("update sensor_acquisition_contracts set revoked_at=clock_timestamp() where user_id='$user'")
            } }
            expectFailure("42501") { connection.createStatement().use {
                it.execute("delete from sensor_acquisition_contracts where user_id='$user'")
            } }
        }
        val work = claimCurrent()
        publish(payload(work, start + 300))
        asRole("authenticated", otherUser) { connection ->
            assertEquals(0L, number(connection, "select count(*) from server_physiology_results where user_id='$user'"))
            expectFailure("42501") { read(connection, "server_scoring_read_contract", user, device) }
        }
        asRole("authenticated", user) { connection ->
            expectFailure("42501") { read(connection, "server_scoring_read_contract", user, otherDevice) }
        }
    }

    @Test fun originalPacketSourceBindingAndOneWayReceiptRevocationControlVerifiedTiming() {
        val (packets, json) = SensorFixtures.beats()
        val proof = owned(json)
        insertPackets(packets)
        val reader = SignalSampleReader(db)
        val untimed = reader.loadDay(user, day, device, "UTC")!!.hrvObservations!!
        assertEquals(300, untimed.size)
        assertTrue(untimed.all { it.verifiedSpan == null })
        assertEquals("timing_coverage_unverified", HrvWindow.measure(start.toInt(), untimed).reason)

        val beforeReceipt = revision()
        insertReceipt(proof)
        assertTrue(revision() > beforeReceipt)
        val timed = reader.loadDay(user, day, device, "UTC")!!.hrvObservations!!
        assertEquals(300, timed.count { it.verifiedSpan != null })
        val measured = HrvWindow.measure(start.toInt(), timed)
        assertTrue(measured.reason, measured.measurementValid)
        assertEquals("ppg_ibi", measured.modality)
        assertEquals(0.0, measured.observedRMSSD!!, 0.0)
        assertEquals(0.0, measured.sdnn!!, 0.0)

        sql("update noop_rr_packet_provenance set source_id='${UUID.randomUUID()}' " +
            "where user_id='$user' and \"packetId\"='${packets.first().packetId}'")
        assertTrue(reader.loadDay(user, day, device, "UTC")!!.hrvObservations!!.all { it.verifiedSpan == null })
        sql("update noop_rr_packet_provenance set source_id='$source' where user_id='$user'")
        assertEquals(300, reader.loadDay(user, day, device, "UTC")!!.hrvObservations!!.count { it.verifiedSpan != null })

        expectFailure("P0001") { sql("update sensor_acquisition_contracts set created_at=created_at+interval '1 second' where user_id='$user'") }
        val beforeRevocation = revision()
        sql("update sensor_acquisition_contracts set revoked_at=clock_timestamp() where user_id='$user'")
        assertTrue(revision() > beforeRevocation)
        val revoked = reader.loadDay(user, day, device, "UTC")!!
        assertTrue(revoked.acquisitionEvidence.receipts.isEmpty())
        assertTrue(revoked.hrvObservations!!.all { it.verifiedSpan == null })
        expectFailure("P0001") { sql("update sensor_acquisition_contracts set revoked_at=null where user_id='$user'") }

        val beforeReplacement = revision()
        insertReceipt(proof.put("capture_evidence_sha256", "5".repeat(64)))
        assertTrue(revision() > beforeReplacement)
        assertEquals(2L, number("select count(*) from sensor_acquisition_contracts where user_id='$user'"))
        assertEquals(1, reader.loadDay(user, day, device, "UTC")!!.acquisitionEvidence.receipts.size)
        assertEquals(300, reader.loadDay(user, day, device, "UTC")!!.hrvObservations!!.count { it.verifiedSpan != null })
    }

    @Test fun actualWorkerPayloadReadbackKeepsDiagnosticValuesNullAndCanonicalContractUnchanged() {
        val (packets, json) = SensorFixtures.beats()
        insertPackets(packets)
        val proof = owned(json)
        insertReceipt(proof)
        exportFixture("hrv-acquisition.json", replayMetadata(proof).put("original_packets", JSONArray(packets.map { packet ->
            JSONObject().put("packetId",packet.packetId).put("ts",packet.ts).put("sensorTs",packet.sensorTs)
                .put("recordIndex",packet.recordIndex).put("rawHex",packet.rawHex).put("source_id",source.toString())
                .put("decoderVersion",packet.decoderVersion).put("clockVersion",packet.clockVersion)
                .put("declaredCount",packet.declaredCount)
        })))
        val work = claimCurrent()
        val scored = payload(work, start + 900)
        assertEquals(13, scored.getJSONArray("signal_windows").length())
        val analyzed = window(scored, "hrv")
        assertEquals("available", analyzed.getString("measurement_status"))
        assertEquals(0.0, analyzed.getJSONObject("values").getDouble("observed_rmssd_ms"), 0.0)
        exportFixture("hrv-worker-payload.json", scored)
        publish(scored)
        assertTrue(queue.markDone(work, 1))
        val stored = JSONObject(string("select payload::text from server_physiology_results " +
            "where user_id='$user' and input_revision=${work.inputRevision}"))
        assertTrue("JSONB preserves every window field and numeric value",
            scored.getJSONArray("signal_windows").similar(stored.getJSONArray("signal_windows")))

        asRole("service_role", user) { connection ->
            val actual = read(connection, "server_scoring_for_device_day", user, device)
            exportFixture("hrv-score-api.json", actual)
            val previous = read(connection, "server_scoring_read_contract_before_signals", user, device)
            val unchanged = JSONObject(actual.toString()).apply { remove("signal_windows"); remove("signal_windows_device_id") }
            assertEquals(previous.toMap(), unchanged.toMap())
            assertEquals(device.toString(), actual.getString("signal_windows_device_id"))
            assertEquals(13, actual.getJSONArray("signal_windows").length())
            for (i in 0 until actual.getJSONArray("signal_windows").length()) {
                assertTrue(actual.getJSONArray("signal_windows").getJSONObject(i).isNull("values"))
            }
            val diagnostic = window(actual, "hrv")
            assertEquals("available", diagnostic.getString("analysis_status"))
            assertEquals("unqualified", diagnostic.getString("measurement_status"))
            assertEquals("not_reference_validated", diagnostic.getString("reason"))
            assertEquals("shadow", diagnostic.getString("publication_status"))
            assertEquals("snapshot", diagnostic.getString("freshness_status"))
            assertEquals(work.inputRevision, diagnostic.getLong("required_revision"))
            val oxygen = window(actual, "spo2")
            assertEquals("blocked", oxygen.getString("measurement_status"))
            assertEquals("supported_calibrated_source_not_validated", oxygen.getString("reason"))
        }
        sql("update sensor_acquisition_contracts set revoked_at=clock_timestamp() where user_id='$user'")
        asRole("service_role", user) { connection ->
            val stale = window(read(connection, "server_scoring_for_device_day", user, device), "hrv")
            assertTrue(stale.isNull("values"))
            assertEquals("stale", stale.getString("freshness_status"))
            assertTrue(stale.getLong("required_revision") > work.inputRevision)
        }
        assertEquals(1L, number("select count(*) from server_physiology_results where user_id='$user'"))
    }

    @Test fun closedWindowsAdvanceRevisionsOnceAndCompletedDaysDoNotRequeueForever() {
        val first = claimCurrent()
        publish(payload(first, start + 300))
        assertTrue(queue.markDone(first, 1))
        enqueueClosed(start + 599)
        assertEquals(first.inputRevision, revision())
        enqueueClosed(start + 600)
        assertEquals(first.inputRevision + 1, revision())
        enqueueClosed(start + 899)
        assertEquals(first.inputRevision + 1, revision())
        val next = claimCurrent()
        publish(payload(next, start + 600))
        assertTrue(queue.markDone(next, 1))

        val dayEnd = start + 86400
        enqueueClosed(dayEnd + 300)
        assertEquals(next.inputRevision + 1, revision())
        val finished = claimCurrent()
        val finalPayload = payload(finished, dayEnd)
        assertEquals(288 * 4 + 96, finalPayload.getJSONArray("signal_windows").length())
        publish(finalPayload)
        assertTrue(queue.markDone(finished, 1))
        enqueueClosed(dayEnd + 900)
        enqueueClosed(dayEnd + 1800)
        assertEquals(finished.inputRevision, revision())
        assertEquals(1L, number("select count(*) from physiology_work_items where user_id='$user' and day='$day' and done_at is not null"))
    }

    @Test fun rawArrivalDecodesActualBytesAndWithdrawalInvalidatesDependentWindows() {
        val synthetic = ownedRaw("ppg")
        val manifest = synthetic.manifest
        val proof = synthetic.proof
        insertReceipt(proof)
        exportRaw(synthetic)
        val beforeArrival = revision()
        val reader = SignalSampleReader(db)
        assertTrue(reader.loadDay(user, day, device, "UTC")!!.rawManifests.isEmpty())
        insertRaw(synthetic)
        assertTrue(revision() > beforeArrival)
        val inputs = reader.loadDay(user, day, device, "UTC")!!
        assertEquals(source, inputs.rawManifests.single().sourceId)
        var fetches = 0
        BoundedRawFeatureLane(object : B2ObjectStore.GetClient {
            override fun getObject(key: String, maximumBytes: Int): ByteArray {
                assertEquals(manifest.key, key)
                assertTrue(synthetic.bytes.size <= maximumBytes)
                fetches++
                return synthetic.bytes
            }
        }).use { lane ->
            val work = claimCurrent()
            val scored = payload(work, start + 300, DayScorer(rawFeatures=lane))
            val pulse = window(scored, "ppg")
            assertEquals("available", pulse.getString("measurement_status"))
            assertEquals("vps_estimate", pulse.getString("provenance"))
            assertEquals(60.0, pulse.getJSONObject("values").getDouble("heart_rate_bpm"), 2.0)
            assertEquals(1, fetches)
            exportFixture("ppg-worker-payload.json", scored)
            publish(scored)
            assertTrue(queue.markDone(work, 1))
            asRole("service_role", user) { connection ->
                val api = read(connection, "server_scoring_for_device_day", user, device)
                exportFixture("ppg-score-api.json", api)
                val read = window(api, "ppg")
                assertEquals("unqualified", read.getString("measurement_status"))
                assertTrue(read.isNull("values"))
            }
        }
        val beforeWithdrawal = revision()
        sql("update object_manifests set status='failed' where id='${manifest.id}'")
        assertTrue(revision() > beforeWithdrawal)
        assertTrue(reader.loadDay(user, day, device, "UTC")!!.rawManifests.isEmpty())
        val withdrawn = payload(claimCurrent(), start + 300)
        assertEquals("archive_pending", window(withdrawn, "ppg").getString("reason"))
        assertTrue(window(withdrawn, "ppg").isNull("values"))
    }

    @Test fun actualColumnarImuAndPointTemperatureKeepUnitsCoverageSourceAndWearGates() {
        val raw = ownedRaw("imu")
        insertReceipt(raw.proof)
        insertRaw(raw)
        exportRaw(raw)
        for ((offset, value) in listOf(10 to 3200, 150 to 3250, 290 to 3300)) {
            sql("insert into noop_skin_temp_samples(user_id,device_id,source_id,ts,raw,batch_id) " +
                "values('$user','$device','$source',${start+offset},$value,'${UUID.randomUUID()}')")
        }
        val samples = SignalSampleReader(db).loadDay(user, day, device, "UTC")!!.skinTemp
        assertEquals(3, samples.size)
        val scalarIdentity = samples.joinToString(";") { "${it.ts}:${it.raw}:${it.aux1Raw}:${it.aux2Raw}" }
        val thermalProof = owned(SensorFixtures.base("temperature")).put("unit","celsius_centi").put("wear_status","on_body")
            .put("scalar_sha256",SensorAcquisitionProof.sha256(scalarIdentity.toByteArray()))
        insertReceipt(thermalProof)
        exportFixture("temperature-acquisition.json",replayMetadata(thermalProof).put("scalar_samples",JSONArray(samples.map {
            JSONObject().put("ts",it.ts).put("raw",it.raw).put("aux1Raw",it.aux1Raw ?: JSONObject.NULL)
                .put("aux2Raw",it.aux2Raw ?: JSONObject.NULL).put("source_id",source.toString())
        })))

        BoundedRawFeatureLane(object : B2ObjectStore.GetClient {
            override fun getObject(key: String, maximumBytes: Int): ByteArray {
                assertEquals(raw.manifest.key,key); assertTrue(raw.bytes.size<=maximumBytes)
                return raw.bytes
            }
        }).use { lane ->
            val scorer = DayScorer(rawFeatures=lane)
            val work = claimCurrent()
            val scored = payload(work,start+300,scorer)
            val motion = window(scored,"imu")
            assertEquals("available",motion.getString("measurement_status"))
            assertEquals("m_s2_and_rad_s",motion.getString("unit"))
            assertEquals(9.81,motion.getJSONObject("values").getDouble("acceleration_magnitude_m_s2"),.00001)
            assertEquals(0.0,motion.getJSONObject("values").getDouble("gyroscope_rms_rad_s"),0.0)
            assertEquals(1.0,motion.getDouble("observed_fraction"),0.0)
            val thermal = window(scored,"temperature")
            assertEquals("available",thermal.getString("measurement_status"))
            assertEquals("degC_skin",thermal.getString("unit"))
            assertEquals(32.5,thermal.getJSONObject("values").getDouble("median_skin_c"),0.0)
            assertEquals(.5,thermal.getJSONObject("values").getDouble("mad_skin_c"),0.0)
            assertEquals(3,thermal.getInt("observed_sample_count"))
            assertTrue(thermal.isNull("observed_fraction"))
            assertEquals("point_observations_not_continuous_duration",thermal.getJSONObject("quality").getString("coverage_kind"))
            exportFixture("imu-temperature-worker-payload.json",scored)
            publish(scored)
            assertTrue(queue.markDone(work,1))
            asRole("service_role",user) { connection ->
                val api=read(connection,"server_scoring_for_device_day",user,device)
                exportFixture("imu-temperature-score-api.json",api)
                for(kind in listOf("imu","temperature")) {
                    assertEquals("available",window(api,kind).getString("analysis_status"))
                    assertEquals("unqualified",window(api,kind).getString("measurement_status"))
                    assertTrue(window(api,kind).isNull("values"))
                }
            }

            sql("update noop_skin_temp_samples set source_id='${UUID.randomUUID()}' where user_id='$user' and ts=${start+10}")
            val mismatched = window(payload(claimCurrent(),start+300,scorer),"temperature")
            assertEquals("capture_source_mismatch",mismatched.getString("reason"))
            assertTrue(mismatched.isNull("values"))
            sql("update noop_skin_temp_samples set source_id='$source' where user_id='$user'")
            sql("insert into noop_events(user_id,device_id,source_id,ts,kind,\"payloadJSON\",batch_id) " +
                "values('$user','$device','$source',${start+50},'WRIST_OFF(10)','{}','${UUID.randomUUID()}')")
            val offBody = window(payload(claimCurrent(),start+300,scorer),"temperature")
            assertEquals("off_body",offBody.getString("reason"))
            assertEquals("unavailable",offBody.getString("measurement_status"))
            assertTrue(offBody.isNull("values"))
        }
    }

    private fun ownedRaw(kind: String): SensorFixtures.Raw = SensorFixtures.raw(kind).let { raw -> raw.copy(
        manifest=raw.manifest.copy(userId=user,deviceId=device,sourceId=source,
            key="v3/raw/users/$user/devices/$device/${raw.manifest.id}"),proof=owned(raw.proof)) }

    private fun insertRaw(raw: SensorFixtures.Raw) {
        val manifest=raw.manifest
        val kind=raw.proof.getString("kind")
        val stream=if(kind=="ppg") "ppgWaveformSample" else "rawImuSession"
        sql("insert into object_manifests(id,user_id,device_id,source_id,object_key,status,sha256_source,sha256,compression,format," +
            "object_class,object_kind,compressed_bytes,uncompressed_bytes,sample_count) values " +
            "('${manifest.id}','$user','$device','$source','${manifest.key}','ready','client_claimed','${manifest.sha256}'," +
            "'none','noop_push_npb1','raw','noop_$kind',${raw.bytes.size},${raw.bytes.size},300)")
        sql("insert into noop_signal_windows(user_id,device_id,stream,hour_start,object_id,object_key,start_ts,end_ts,received_records) " +
            "values('$user','$device','$stream',$start,'${manifest.id}','${manifest.key}',$start,${start+300},300)")
    }

    private fun exportRaw(raw: SensorFixtures.Raw) {
        val manifest=raw.manifest
        val kind=raw.proof.getString("kind")
        exportFixture("$kind-acquisition.json",replayMetadata(raw.proof)
            .put("raw_bytes_base64",Base64.getEncoder().encodeToString(raw.bytes))
            .put("manifest",JSONObject().put("id",manifest.id.toString()).put("user_id",user.toString())
                .put("device_id",device.toString()).put("source_id",source.toString()).put("object_key",manifest.key)
                .put("sha256",manifest.sha256).put("compression",manifest.compression).put("format",manifest.format)
                .put("compressed_bytes",manifest.compressedBytes).put("uncompressed_bytes",manifest.uncompressedBytes)
                .put("sample_count",manifest.records).put("start_ts",manifest.start).put("end_ts",manifest.end)
                .put("stream",if(kind=="ppg") "ppgWaveformSample" else "rawImuSession")
                .put("status","ready").put("object_class","raw").put("object_kind","noop_$kind")))
    }

    private fun owned(json: JSONObject): JSONObject = json.put("user_id", user.toString()).put("device_id", device.toString())
        .apply { getJSONObject("cohort").put("source_id", source.toString()) }

    private fun exportFixture(name: String, payload: JSONObject) {
        val directory = System.getenv("SENSOR_TEST_OUTPUT")?.let(Path::of) ?: return
        Files.createDirectories(directory)
        Files.writeString(directory.resolve(name), payload.toString(2) + "\n")
    }

    private fun replayMetadata(proof: JSONObject): JSONObject {
        val receipt = SensorFixtures.receipt(proof)
        return JSONObject().put("fixture_only",true).put("validation_scope","synthetic_not_device_qualification")
            .put("user_id",user.toString()).put("device_id",device.toString()).put("source_id",source.toString()).put("day",day)
            .put("proof",proof).put("contract_sha256",receipt.digest)
            .put("contract_bytes_base64",Base64.getEncoder().encodeToString(receipt.bytes))
    }

    private fun insertReceipt(json: JSONObject) = db.withConnection { insertReceipt(it, json) }
    private fun insertReceipt(connection: Connection, json: JSONObject) {
        val receipt = SensorFixtures.receipt(json)
        connection.prepareStatement("insert into sensor_acquisition_contracts " +
            "(user_id,device_id,kind,scope_start_s,scope_end_s,contract_sha256,contract_bytes) values (?,?,?,?,?,?,?)").use {
            it.setObject(1,user); it.setObject(2,device); it.setString(3,receipt.kind)
            it.setLong(4,receipt.start); it.setLong(5,receipt.end); it.setString(6,receipt.digest); it.setBytes(7,receipt.bytes)
            it.executeUpdate()
        }
    }

    private fun insertPackets(packets: List<RrPacketProvenance>) = db.withConnection { connection ->
        connection.prepareStatement("""
            insert into noop_rr_packet_provenance
            (user_id,device_id,source_id,"packetId",ts,"sensorTs","recordIndex","rawHex","srcChannel",
             "schemaVersion","decoderVersion","clockVersion","timestampPrecisionSeconds","clockOffsetSeconds","declaredCount")
            values (?,?,?,?,?,?,?,?,5,1,?,?,1,0,?)
        """.trimIndent()).use { statement ->
            for (packet in packets) {
                statement.setObject(1,user); statement.setObject(2,device); statement.setObject(3,source)
                statement.setString(4,packet.packetId); statement.setLong(5,packet.ts); statement.setLong(6,packet.sensorTs)
                statement.setLong(7,packet.recordIndex); statement.setString(8,packet.rawHex)
                statement.setString(9,packet.decoderVersion); statement.setString(10,packet.clockVersion)
                statement.setInt(11,packet.declaredCount); statement.addBatch()
            }
            statement.executeBatch()
        }
        Unit
    }

    private fun claimCurrent(): ScoringWorkQueue.WorkItem {
        if (revision() == 0L) queue.dirtyWorkItem(user, device, day)
        sql("update physiology_work_items set next_attempt_at=clock_timestamp() where user_id='$user' and device_id='$device' and day='$day'")
        return requireNotNull(queue.claimOne(user, device, day))
    }

    private fun payload(work: ScoringWorkQueue.WorkItem, computedAt: Long, scorer: DayScorer = DayScorer()): JSONObject {
        val inputs = SignalSampleReader(db).loadDay(user, day, device, "UTC")!!
        return CanonicalScorePayload.build(scorer.score(inputs, CanonicalScorePayload.ALGORITHM_VERSION,
            work.inputRevision.toString(), Instant.ofEpochSecond(computedAt)))
            .put("input_revision",work.inputRevision).put("run_id",work.runId.toString()).put("lease_token",work.leaseToken.toString())
    }

    private fun window(payload: JSONObject, kind: String): JSONObject = payload.getJSONArray("signal_windows").let { windows ->
        (0 until windows.length()).map(windows::getJSONObject).first { it.getString("kind") == kind }
    }
    private fun publish(payload: JSONObject) = db.withConnection { connection ->
        connection.prepareStatement("select engine_publish_physiology('test',?::jsonb)").use {
            it.setString(1,payload.toString()); it.execute(); Unit
        }
    }
    private fun enqueueClosed(now: Long) = sql("select sensor_enqueue_closed_windows(to_timestamp($now),16)")
    private fun revision(): Long = number("select coalesce(max(input_revision),0) from physiology_work_items " +
        "where user_id='$user' and device_id='$device' and day='$day'")
    private fun read(connection: Connection, function: String, owner: UUID, selected: UUID): JSONObject =
        connection.createStatement().use { it.executeQuery("select $function('$owner','$day','$selected')").use { rows ->
            check(rows.next()); JSONObject(rows.getString(1))
        } }
    private fun asRole(role: String, owner: UUID, action: (Connection) -> Unit) = db.withConnection { connection ->
        connection.createStatement().use { statement ->
            statement.execute("set role $role")
            try {
                statement.execute("select set_config('request.jwt.claim.sub','$owner',false)")
                statement.execute("select set_config('request.jwt.claim.role','$role',false)")
                action(connection)
            } finally {
                statement.execute("reset role")
                statement.execute("select set_config('request.jwt.claim.sub','',false)")
                statement.execute("select set_config('request.jwt.claim.role','',false)")
            }
        }
    }
    private fun sql(query: String) = db.withConnection { connection -> connection.createStatement().use { it.execute(query); Unit } }
    private fun string(query: String): String = db.withConnection { connection -> connection.createStatement().use {
        it.executeQuery(query).use { rows -> check(rows.next()); rows.getString(1) }
    } }
    private fun number(query: String) = db.withConnection { number(it, query) }
    private fun number(connection: Connection, query: String): Long = connection.createStatement().use {
        it.executeQuery(query).use { rows -> check(rows.next()); rows.getLong(1) }
    }
    private fun expectFailure(state: String, action: () -> Unit) {
        try { action(); fail("expected SQLSTATE $state") }
        catch (error: SQLException) { assertEquals(state, error.sqlState) }
    }
}
