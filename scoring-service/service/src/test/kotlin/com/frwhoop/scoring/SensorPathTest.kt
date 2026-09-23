package com.frwhoop.scoring

import com.frwhoop.scoring.b2.B2ObjectStore
import com.frwhoop.scoring.db.SensorAcquisitionReader
import com.frwhoop.scoring.db.SignalSampleReader
import com.frwhoop.scoring.scoring.CanonicalScorePayload
import com.frwhoop.scoring.scoring.DayScorer
import com.frwhoop.scoring.signals.*
import com.noop.analytics.HrvWindow
import com.noop.analytics.UserProfile
import com.noop.protocol.Crc
import com.noop.protocol.DeviceFamily
import com.noop.protocol.RrPacketProvenance
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.Instant
import java.util.UUID
import java.util.concurrent.CountDownLatch
import kotlin.math.PI
import kotlin.math.sin

internal object SensorFixtures {
    val user = UUID.fromString("11111111-1111-4111-8111-111111111111")
    val device = UUID.fromString("22222222-2222-4222-8222-222222222222")
    val source = UUID.fromString("33333333-3333-4333-8333-333333333333")
    const val start=1787011200L
    fun base(kind: String) = JSONObject().put("schema_version",1).put("qualification","verified_capture_metadata")
        .put("user_id",user.toString()).put("device_id",device.toString()).put("kind",kind).put("start",start).put("end",start+300)
        .put("capture_evidence_sha256","1".repeat(64)).put("independent_clock_evidence_sha256","2".repeat(64))
        .put("reference_capture_sha256","3".repeat(64)).put("clock_id","synthetic-reference-clock")
        .put("clock_method","independent_capture_reference").put("clock_uncertainty_seconds",.001)
        .put("cohort",JSONObject().put("hardware","WHOOP5").put("firmware","synthetic-fixture")
            .put("os","fixture").put("os_version","fixture").put("app_build","fixture").put("capture_mode","development")
            .put("source_id",source.toString()).put("session_id","synthetic-no-participant"))
    fun receipt(j: JSONObject): SensorAcquisitionProof.Receipt = j.toString().toByteArray().let {
        SensorAcquisitionProof.Receipt(j.getString("kind"),j.getLong("start"),j.getLong("end"),SensorAcquisitionProof.sha256(it),it)
    }
    fun packet(offset: Int, ticks: List<Int>): RrPacketProvenance {
        val end=24+ticks.size*2
        val bytes=ByteArray(end+4); val b=ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        b.put(0,0xaa.toByte()); b.put(1,1); b.putShort(2,(end-4).toShort()); b.put(4,1)
        b.put(8,47); b.put(9,18); b.putInt(11,offset); b.putInt(15,(start+offset).toInt()); b.put(22,60); b.put(23,ticks.size.toByte())
        ticks.forEachIndexed { i,t -> b.putShort(24+i*2,t.toShort()) }
        b.putShort(6,Crc.crc16Modbus(bytes,0,6).toShort()); b.putInt(end,Crc.crc32(bytes,8,end).toInt())
        return requireNotNull(RrPacketProvenance.checked(bytes))
    }
    fun beats(withZero: Boolean=false): Pair<List<RrPacketProvenance>,JSONObject> {
        val packets=(0 until 300 step 4).map { offset -> packet(offset,List(4) { if(withZero && offset==0 && it==1) 0 else 1024 }) }
        val intervals=JSONArray()
        packets.forEachIndexed { p,packet -> packet.words().forEach { word ->
            val n=p*4+word.index
            intervals.put(JSONObject().put("packet_id",packet.packetId).put("word_index",word.index)
                .put("start_s",if(word.rawTicks==0) JSONObject.NULL else start+n)
                .put("end_s",if(word.rawTicks==0) JSONObject.NULL else start+n+1)
                .put("start_beat_id","b$n").put("end_beat_id","b${n+1}").put("continuity_id","capture"))
        } }
        return packets to base("beat_timing").put("modality","ppg_ibi").put("intervals",intervals).put("decoder_version",packets.first().decoderVersion)
    }
    fun inputs()=SignalSampleReader.DayInputs(user,"2026-08-18",device.toString(),0,start,start+899,UserProfile(),start,start+899,
        emptyList(),emptyList(),emptyList(),emptyList(),emptyList(),DeviceFamily.WHOOP5)
    data class Raw(val bytes: ByteArray,val manifest: VerifiedRawObjectReader.Manifest,val proof: JSONObject)
    fun raw(kind: String="ppg",flat: Boolean=false): Raw {
        val count=300; val columns=if(kind=="ppg")24 else 600
        val bytes=ByteBuffer.allocate(10+count*(16+(if(kind=="ppg")9 else 0)+4+columns*2)).order(ByteOrder.LITTLE_ENDIAN)
        bytes.put("NPB1".toByteArray()).put(if(kind=="ppg")2 else 1).put(if(kind=="ppg")1 else 4).putInt(count)
        for(second in 0 until count) {
            bytes.putLong(second+1L).putLong(start+second)
            if(kind=="ppg") bytes.put(0).putLong(second.toLong())
            bytes.putInt(columns*2)
            for(sample in 0 until columns) bytes.putShort(when {
                flat -> 0
                kind=="ppg" -> (1000*sin(2*PI*sample/24)).toInt().toShort()
                sample in 200..299 -> 1000.toShort()
                else -> 0
            })
        }
        val raw=bytes.array(); val id=UUID.randomUUID()
        val manifest=VerifiedRawObjectReader.Manifest(id,user,device,"v3/raw/users/$user/devices/$device/o",
            SensorAcquisitionProof.sha256(raw),"none","noop_push_npb1",raw.size,raw.size,count,start,start+300,source)
        val records=JSONArray((0 until count).map { i -> JSONObject().put("object_id",id.toString()).put("object_sha256",manifest.sha256)
            .put("row_id",i+1).put("sensor_second",start+i).put("record_index",i).put("start_s",start+i) })
        val proof=base(kind).put("records",records).put("decoder_version",VerifiedRawObjectReader.VERSION)
            .put("channels",JSONArray(if(kind=="ppg") listOf("ppg") else listOf("ax","ay","az","gx","gy","gz")))
            .put("sample_rate_hz",if(kind=="ppg")24 else 100).put("unit","adc_count").put("wavelength_nm",530)
            .put("motion_status","aligned_quiet").put("motion_evidence_sha256","4".repeat(64))
            .put("layout","axis_major_100").put("accelerometer_unit","m_s2").put("gyroscope_unit","rad_s")
            .put("accelerometer_scale",.00981).put("gyroscope_scale",.001)
        return Raw(raw,manifest,proof)
    }

    fun rawShards(kind: String, shardCount: Int): Pair<List<Raw>, JSONObject> {
        require(shardCount in 1..300)
        val original = raw(kind)
        val recordBytes = (original.bytes.size - 10) / 300
        val proof = JSONObject(original.proof.toString())
        val mappings = proof.getJSONArray("records")
        val shards = (0 until shardCount).map { index ->
            val from = 300 * index / shardCount
            val endExclusive = 300 * (index + 1) / shardCount
            val bytes = ByteBuffer.allocate(10 + (endExclusive - from) * recordBytes).order(ByteOrder.LITTLE_ENDIAN)
                .put(original.bytes, 0, 6).putInt(endExclusive - from)
                .put(original.bytes, 10 + from * recordBytes, (endExclusive - from) * recordBytes).array()
            val id = UUID.randomUUID()
            val manifest = original.manifest.copy(id = id, key = original.manifest.key + "/$id",
                sha256 = SensorAcquisitionProof.sha256(bytes), compressedBytes = bytes.size,
                uncompressedBytes = bytes.size, records = endExclusive - from, start = start + from, end = start + endExclusive)
            for (record in from until endExclusive) mappings.getJSONObject(record)
                .put("object_id", id.toString()).put("object_sha256", manifest.sha256)
            Raw(bytes, manifest, proof)
        }
        return shards to proof
    }
}

class SensorPathTest {
    private val f=SensorFixtures
    @Test fun originalPacketToIndependentBeatTimingPreservesValidZeroHrv() {
        val (packets,json)=f.beats(); val receipt=f.receipt(json)
        val rows=SensorAcquisitionProof.beats(SensorAcquisitionProof.verify(receipt,f.user,f.device),packets+packets,f.user,f.device,
            packets.associate { it.packetId to f.source.toString() })
        assertEquals(300,rows.size)
        val value=HrvWindow.measure(f.start.toInt(),rows,inputRevision="1")
        assertTrue(value.reason,value.measurementValid); assertEquals(0.0,value.observedRMSSD!!,0.0); assertEquals(0.0,value.sdnn!!,0.0)
        assertEquals("ppg_ibi",value.modality)
    }
    @Test fun packetReceiptsAloneDoNotCreateTimingAndZeroWordsCannotBridgePairs() {
        val (packets,json)=f.beats(true)
        val unqualified=com.noop.analytics.PhysiologyQuality.checkedPackets(packets,f.device.toString(),f.user.toString())
        assertEquals("timing_coverage_unverified",HrvWindow.measure(f.start.toInt(),unqualified).reason)
        val rows=SensorAcquisitionProof.beats(SensorAcquisitionProof.verify(f.receipt(json),f.user,f.device),packets,f.user,f.device,
            packets.associate { it.packetId to f.source.toString() })
        assertEquals(0.0,rows[1].originalRRMs,0.0); assertNull(rows[1].verifiedSpan)
        assertFalse(rows[0].endBeatAccepted); assertFalse(rows[2].startBeatAccepted)
        assertTrue(HrvWindow.measure(f.start.toInt(),rows).validPairCount < 299)
        json.getJSONArray("intervals").remove(1)
        assertThrows(IllegalArgumentException::class.java) { SensorAcquisitionProof.beats(SensorAcquisitionProof.verify(f.receipt(json),f.user,f.device),packets,f.user,f.device,packets.associate { it.packetId to f.source.toString() }) }
    }
    @Test fun changedOwnerSourceUnknownClockOrDigestCannotQualify() {
        val (packets,j)=f.beats(); val proof=SensorAcquisitionProof.verify(f.receipt(j),f.user,f.device)
        assertThrows(IllegalArgumentException::class.java) { SensorAcquisitionProof.beats(proof,packets,f.user,f.device,emptyMap()) }
        assertThrows(IllegalArgumentException::class.java) { SensorAcquisitionProof.verify(f.receipt(j),UUID.randomUUID(),f.device) }
        assertThrows(IllegalArgumentException::class.java) { SensorAcquisitionProof.verify(f.receipt(j).copy(digest="0".repeat(64)),f.user,f.device) }
        j.put("clock_method","packet_receipt")
        assertThrows(IllegalArgumentException::class.java) { SensorAcquisitionProof.verify(f.receipt(j),f.user,f.device) }
    }
    @Test fun realRawBytesQualifiedDecoderProducesServerPpgHrAndColumnarMotion() {
        for(kind in listOf("ppg","imu")) {
            val raw=f.raw(kind)
            val analyzer=QualifiedRawFeatures(object : B2ObjectStore.GetClient { override fun getObject(key: String,maximumBytes: Int)=raw.bytes })
            val value=analyzer.extract(SensorAcquisitionProof.verify(f.receipt(raw.proof),f.user,f.device),listOf(raw.manifest),f.user,f.device)
            assertEquals(1.0,value.observedFraction,0.0)
            if(kind=="ppg") assertEquals(60.0,value.values.getValue("heart_rate_bpm"),2.0)
            else { assertEquals(9.81,value.values.getValue("acceleration_magnitude_m_s2"),.00001); assertEquals(0.0,value.values.getValue("gyroscope_rms_rad_s"),0.0) }
        }
    }
    @Test fun flatlineWrongSourceAndMisalignedMotionAreRejected() {
        val raw=f.raw(flat=true)
        val analyzer=QualifiedRawFeatures(object : B2ObjectStore.GetClient { override fun getObject(key: String,maximumBytes: Int)=raw.bytes })
        fun extract()=analyzer.extract(SensorAcquisitionProof.verify(f.receipt(raw.proof),f.user,f.device),listOf(raw.manifest),f.user,f.device)
        assertEquals("optical_clipping_or_flatline",assertThrows(IllegalArgumentException::class.java) { extract() }.message)
        raw.proof.put("motion_status","unaligned")
        assertEquals("motion_alignment_unverified",assertThrows(IllegalArgumentException::class.java) { extract() }.message)
        raw.proof.put("motion_status","aligned_quiet").getJSONObject("cohort").put("source_id",UUID.randomUUID().toString())
        assertEquals("capture_source_mismatch",assertThrows(IllegalArgumentException::class.java) { extract() }.message)
    }
    @Test fun shardBoundariesDoNotChangeCompletePpgOrImuWindowFeatures() {
        for (kind in listOf("ppg", "imu")) {
            var reference: QualifiedRawFeatures.Features? = null
            for (count in listOf(1, 9, QualifiedRawFeatures.MAX_MAPPED_RECORDS)) {
                val (shards, proof) = f.rawShards(kind, count)
                val byKey = shards.associate { it.manifest.key to it.bytes }
                var gets = 0
                val analyzer = QualifiedRawFeatures(object : B2ObjectStore.GetClient {
                    override fun getObject(key: String, maximumBytes: Int): ByteArray {
                        gets++; return byKey.getValue(key)
                    }
                })
                val actual = analyzer.extract(SensorAcquisitionProof.verify(f.receipt(proof), f.user, f.device),
                    shards.map { it.manifest }.reversed(), f.user, f.device)
                assertEquals(count, gets)
                assertTrue(actual.values.isNotEmpty())
                assertEquals(1.0, actual.observedFraction, 0.0)
                assertEquals(0.0, actual.maximumGap, 0.0)
                if (reference == null) reference = actual else {
                    assertEquals(reference.values, actual.values)
                    assertEquals(reference.samples, actual.samples)
                    assertEquals(reference.observedThrough, actual.observedThrough, 0.0)
                    assertTrue(reference.quality.similar(actual.quality))
                }
            }
        }
    }
    @Test fun completeShardedWindowBudgetsAndMissingObjectsAbstainBeforeFetchOrInference() {
        val (shards, proof) = f.rawShards("ppg", 9)
        val manifests = shards.map { it.manifest }
        var gets = 0
        BoundedRawFeatureLane(object : B2ObjectStore.GetClient {
            override fun getObject(key: String, maximumBytes: Int): ByteArray {
                gets++; error("budget failure must happen before object access")
            }
        }).use { lane ->
            fun assertAbstains(expected: String, altered: List<VerifiedRawObjectReader.Manifest>, json: JSONObject = proof) {
                val receipt = f.receipt(json)
                val result = lane.evaluate(f.inputs().copy(
                    acquisitionEvidence = SensorAcquisitionReader.Evidence(listOf(receipt)), rawManifests = altered))
                    .getValue(receipt.digest)
                assertEquals(expected, result.reason)
                assertNull(result.features)
                assertEquals(0, gets)
            }
            assertAbstains("archive_pending", manifests.dropLast(1))
            assertAbstains("raw_byte_budget_exceeded", manifests.map { it.copy(compressedBytes = 1024 * 1024) })
            assertAbstains("raw_byte_budget_exceeded", manifests.map { it.copy(uncompressedBytes = 1024 * 1024) })
            val tooMany = JSONObject(proof.toString())
            tooMany.getJSONArray("records").put(JSONObject(tooMany.getJSONArray("records").getJSONObject(0).toString()))
            assertAbstains("raw_sample_budget_exceeded", manifests, tooMany)
        }
    }
    @Test fun nativeAndroidContinuousAndSessionRowsDecodeWithoutInventingCoverage() {
        // Exact zstd bytes produced by CloudImuPushSourceTest.nativeArchiveArtifacts...
        // fixture content SHA256 0963d1308445b704e1c39fe471ac434593aaf3d4b0cb9b9a3f4b4628da758ae4.
        // Two distinct captures share a sensor second. These are transport fixtures, not clock qualification.
        val bytes=java.util.Base64.getDecoder().decode("KLUv/WCSCGUBALBOUEIxAQQCAAAAAQBk0klrsAQAAAIBBwCsgF+OyRxmyQSgAh4A1iyLYCAJ")
        val manifest=VerifiedRawObjectReader.Manifest(UUID.fromString("34468ca2-1e31-5e97-b3d6-02c4d5959b49"),f.user,f.device,
            "v3/raw/users/${f.user}/devices/${f.device}/native-android",
            "0963d1308445b704e1c39fe471ac434593aaf3d4b0cb9b9a3f4b4628da758ae4","zstd","noop_push_npb1",
            bytes.size,2450,2,1800000100,1800000101,f.source)
        val decoded=VerifiedRawObjectReader(object : B2ObjectStore.GetClient {
            override fun getObject(key: String, maximumBytes: Int)=bytes
        }).read(manifest,f.user,f.device)
        assertEquals(listOf(1L,2L),decoded.records.map { it.rowId })
        assertEquals(listOf(1800000100L,1800000100L),decoded.records.map { it.timestamp })
        assertEquals(listOf(2,1),decoded.records.map { it.columns.first() })
        assertTrue(decoded.records.all { it.columns.size==600 && it.columns.drop(1).all { n -> n==0 } })
        assertFalse(decoded.timingVerifiedForWaveforms); assertFalse(decoded.channelSemanticsVerified)
    }
    @Test fun missingAndOverlappingRawSecondsCannotBecomeContinuousCoverage() {
        val raw=f.raw()
        val analyze=QualifiedRawFeatures(object : B2ObjectStore.GetClient { override fun getObject(key: String,maximumBytes: Int)=raw.bytes })
        fun extract(j: JSONObject)=analyze.extract(SensorAcquisitionProof.verify(f.receipt(j),f.user,f.device),listOf(raw.manifest),f.user,f.device)
        val gap=JSONObject(raw.proof.toString())
        repeat(31) { gap.getJSONArray("records").remove(0) }
        assertEquals("insufficient_observed_time",assertThrows(IllegalArgumentException::class.java) { extract(gap) }.message)
        val overlap=JSONObject(raw.proof.toString())
        overlap.getJSONArray("records").getJSONObject(1).put("start_s",f.start)
        assertEquals("raw_time_overlap",assertThrows(IllegalArgumentException::class.java) { extract(overlap) }.message)
    }
    @Test fun cachedRawFeatureDependsOnItsManifestAndOffBodyOverridesOpticalProof() {
        val raw=f.raw(); var gets=0
        val receipt=f.receipt(raw.proof)
        val inputs=f.inputs().copy(acquisitionEvidence=SensorAcquisitionReader.Evidence(listOf(receipt)),rawManifests=listOf(raw.manifest))
        BoundedRawFeatureLane(object : B2ObjectStore.GetClient { override fun getObject(key: String,maximumBytes: Int): ByteArray {
            gets++; return raw.bytes
        } }).use { lane ->
            assertNotNull(lane.evaluate(inputs).getValue(receipt.digest).features)
            val unrelated=raw.manifest.copy(id=UUID.randomUUID())
            val cached=lane.evaluate(inputs.copy(rawManifests=inputs.rawManifests+unrelated))
            assertNotNull(cached.getValue(receipt.digest).features); assertEquals(1,gets)
            val offbody=inputs.copy(events=listOf(com.noop.data.EventRow(f.device.toString(),f.start+20,"WRIST_OFF","{}")))
            val windows=SensorWindows.build(offbody,"1",Instant.ofEpochSecond(f.start+300),emptyList(),cached)
            val pulse=windows.single { it.getString("kind")=="ppg" }
            assertEquals("off_body",pulse.getString("reason")); assertTrue(pulse.isNull("values"))
            assertEquals("archive_pending",lane.evaluate(inputs.copy(rawManifests=emptyList())).getValue(receipt.digest).reason)
            assertEquals("capture_source_mismatch",lane.evaluate(inputs.copy(rawManifests=listOf(raw.manifest.copy(sourceId=UUID.randomUUID())))).getValue(receipt.digest).reason)
        }
    }
    @Test fun fiveMinuteGridAndFifteenMinuteSpo2AttemptsKeepMissingValues() {
        val inputs=f.inputs(); val computed=Instant.ofEpochSecond(f.start+900)
        val windows=SensorWindows.build(inputs,"1",computed,emptyList(),emptyMap())
        assertEquals(13,windows.size); assertEquals(3,windows.count { it.getString("kind")=="hrv" })
        assertTrue(windows.all { it.getLong("end")<=computed.epochSecond })
        assertEquals("blocked",windows.single { it.getString("kind")=="spo2" }.getString("measurement_status"))
        assertTrue(windows.filter { it.getString("kind")!="hrv" }.all { it.isNull("values") })
        assertEquals(windows.map { it.getString("window_id") },SensorWindows.build(inputs,"2",computed,emptyList(),emptyMap()).map { it.getString("window_id") })
        val actual=CanonicalScorePayload.build(DayScorer().score(inputs,CanonicalScorePayload.ALGORITHM_VERSION,"1",computed))
        assertEquals(13,actual.getJSONArray("signal_windows").length())
    }
    @Test fun stalledOptionalRawFetchCannotHoldDeterministicWindows() {
        val raw=f.raw(); val release=CountDownLatch(1)
        val lane=BoundedRawFeatureLane(object : B2ObjectStore.GetClient { override fun getObject(key: String,maximumBytes: Int): ByteArray {
            try { release.await() } catch(_: InterruptedException) { release.await() }; return raw.bytes
        } },50)
        try {
            val inputs=f.inputs().copy(acquisitionEvidence=SensorAcquisitionReader.Evidence(listOf(f.receipt(raw.proof))),rawManifests=listOf(raw.manifest))
            val began=System.nanoTime(); val result=lane.evaluate(inputs)
            assertTrue((System.nanoTime()-began)/1e6<1000)
            assertEquals("raw_budget_exceeded",result.values.single().reason)
            assertEquals("raw_worker_busy",lane.evaluate(inputs).values.single().reason)
            assertEquals(13,SensorWindows.build(inputs,"1",Instant.ofEpochSecond(f.start+900),emptyList(),result).size)
        } finally { release.countDown(); lane.close() }
    }
}
