package com.noop.push

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PushBinaryProtocolTest {
    @Test fun singleSecondRawCaptureGetsHalfOpenManifestAndRetainsOriginalEvidenceOnRetry() {
        val row = rawCapture(1_700_000_000, 1_700_000_000)
        val decoded = PushBinaryCodec.pack(PushBinaryTable.RAW_BATCH, listOf(PushBinaryRow.RawBatch(row)))
        assertEquals("4e5042310103070062617463682d3164000000000000005a00000000000000640000000000000000f153650000000000f153650000000002000000040000000400000001020304",
            decoded.joinToString("") { "%02x".format(it) })
        val first = rawObject(row)
        val retry = rawObject(row)
        assertEquals(1_700_000_000L, first.startTs)
        assertEquals(1_700_000_001L, first.endTs)
        assertEquals(2, first.sampleCount)
        assertEquals("81e90626f5f4bfef74c2da704ec899e08eb4655d5d60624116521efef4968d42", first.contentSha256)
        assertEquals("66e88d6c-184b-562d-a049-24e59feaf04a", first.batchId)
        assertEquals("4b2e1680-76d5-56bd-89ae-419dae696a57", first.objectId)
        assertArrayEquals(first.manifestJSON, retry.manifestJSON)
        assertArrayEquals(first.payload, retry.payload)
        assertArrayEquals(PushBinaryCompression.compressObject(decoded, "zstd"), first.payload)
        assertNull(first.endCursor)
        assertNull(retry.endCursor)
        val manifest = JSONObject(first.manifestJSON.toString(Charsets.UTF_8))
        assertEquals(1_700_000_001L, manifest.getLong("endTs"))
        assertFalse(manifest.has("coverage"))
    }

    @Test fun multiSecondRawCaptureKeepsPackedInclusiveEnd() {
        val row = rawCapture(100, 200)
        val decoded = PushBinaryCodec.pack(PushBinaryTable.RAW_BATCH, listOf(PushBinaryRow.RawBatch(row)))
        assertEquals(RAW_BATCH_PACK_HEX, decoded.joinToString("") { "%02x".format(it) })
        val batch = rawObject(row)
        assertEquals(100L, batch.startTs)
        assertEquals(201L, batch.endTs)
        assertEquals(RAW_BATCH_SHA, batch.contentSha256)
        assertEquals(RAW_BATCH_BATCH_ID, batch.batchId)
        assertEquals(RAW_BATCH_OBJECT_ID, batch.objectId)
        assertNull(batch.endCursor)
    }

    @Test fun rawCaptureBoundsRejectReversalAndOverflowWithoutWrap() {
        for (row in listOf(rawCapture(101, 100), rawCapture(100, Long.MAX_VALUE))) {
            assertThrows(PushProtocolException::class.java) { rawObject(row) }
        }
    }

    private fun rawCapture(start: Long, end: Long) = PushRawBatchRecord(
        rowId = 1, batchId = "batch-1", capturedAt = 100, deviceClockRef = 90, wallClockRef = 100,
        startTs = start, endTs = end, frameCount = 2, byteSize = 4, framesBlob = byteArrayOf(1, 2, 3, 4))

    private fun rawObject(row: PushRawBatchRecord) = PushProtocol.binaryObjectBatch(
        PushBinaryTable.RAW_BATCH, SOURCE_A, "strap-a", null, listOf(PushBinaryRow.RawBatch(row)),
        protocolVersion = PushProtocol.OBJECT_VERSION, decodedLimit = PushProtocol.MAX_OBJECT_DECODED_BYTES)

    @Test
    fun ppgBinaryObjectIsDeterministic() {
        val rows = listOf(
            PushBinaryRow.PpgWaveform(
                PushPpgWaveformRecord(rowId = 10, ts = 100, burstIndex = 2, samples = byteArrayOf(0x01, 0x02)),
            ),
            PushBinaryRow.PpgWaveform(
                PushPpgWaveformRecord(rowId = 11, ts = 101, burstIndex = null, samples = byteArrayOf(0x03)),
            ),
        )
        val decoded = PushBinaryCodec.pack(PushBinaryTable.PPG_WAVEFORM_SAMPLE, rows)
        assertEquals(PPG_PACK_HEX, decoded.joinToString("") { "%02x".format(it) })
        assertEquals(PPG_CONTENT_SHA256, PushBinaryCodec.sha256Hex(decoded))

        val first = PushProtocol.binaryObjectBatch(
            PushBinaryTable.PPG_WAVEFORM_SAMPLE, SOURCE_A, "strap-a", null, rows,
        )
        val retry = PushProtocol.binaryObjectBatch(
            PushBinaryTable.PPG_WAVEFORM_SAMPLE, SOURCE_A, "strap-a", null, rows,
        )

        assertEquals(first.batchId, retry.batchId)
        assertEquals(PPG_BATCH_ID, first.batchId)
        assertEquals(PPG_OBJECT_ID, first.objectId)
        assertEquals(first.objectId, retry.objectId)
        assertEquals(first.contentSha256, retry.contentSha256)
        assertArrayEquals(first.payload, retry.payload)
        assertEquals("gzip", first.contentEncoding)
        val manifest = JSONObject(first.manifestJSON.toString(Charsets.UTF_8))
        assertEquals("binaryObject", manifest.getString("type"))
        assertEquals("ppgWaveformSample", manifest.getString("stream"))
        assertEquals(2, manifest.getInt("sampleCount"))
    }

    @Test
    fun binaryAckMatchesBatch() {
        val batch = PushProtocol.binaryObjectBatch(
            PushBinaryTable.V18_AUX_SAMPLE,
            SOURCE_A,
            "strap",
            null,
            listOf(PushBinaryRow.V18Aux(PushV18AuxRecord(rowId = 1, ts = 10, fields = byteArrayOf(0xAB.toByte())))),
        )
        val ack = PushAck(
            protocolVersion = batch.protocolVersion,
            batchId = batch.batchId,
            stream = batch.wireName,
            deviceId = batch.deviceId,
            endCursor = batch.endCursor,
            acceptedRows = batch.sampleCount,
            status = "accepted",
        )
        assertTrue(ack.exactlyMatches(batch))
        assertEquals(V18_END_FINGERPRINT, batch.endCursor?.naturalKeyFingerprint)
    }

    @Test
    fun binaryObjectOracleLiterals() {
        val ppgNoBurst = listOf(
            PushBinaryRow.PpgWaveform(
                PushPpgWaveformRecord(rowId = 5, ts = 50, burstIndex = null, samples = byteArrayOf(0x0A)),
            ),
        )
        val ppgNoBurstDecoded = PushBinaryCodec.pack(PushBinaryTable.PPG_WAVEFORM_SAMPLE, ppgNoBurst)
        assertEquals(PPG_NO_BURST_PACK_HEX, ppgNoBurstDecoded.joinToString("") { "%02x".format(it) })
        val ppgNoBurstBatch = PushProtocol.binaryObjectBatch(
            PushBinaryTable.PPG_WAVEFORM_SAMPLE, SOURCE_A, "strap-a", null, ppgNoBurst,
            protocolVersion = PushProtocol.OBJECT_VERSION,
            decodedLimit = PushProtocol.MAX_OBJECT_DECODED_BYTES,
        )
        assertEquals(PPG_NO_BURST_SHA, ppgNoBurstBatch.contentSha256)
        assertEquals(PPG_NO_BURST_BATCH_ID, ppgNoBurstBatch.batchId)
        assertEquals(PPG_NO_BURST_OBJECT_ID, ppgNoBurstBatch.objectId)

        val imuRow = PushRawImuRecord(1_700_000_000, 1_700_000_000, imuColumns(-1))
        val imuDecoded = PushBinaryCodec.pack(
            PushBinaryTable.RAW_IMU_SESSION,
            listOf(PushBinaryRow.RawImuSession(imuRow)),
        )
        assertEquals(RAW_IMU_PACK_HEX, imuDecoded.joinToString("") { "%02x".format(it) })
        val imuBatch = PushProtocol.binaryObjectBatch(
            PushBinaryTable.RAW_IMU_SESSION, SOURCE_A, "strap-a", null,
            listOf(PushBinaryRow.RawImuSession(imuRow)),
            protocolVersion = PushProtocol.OBJECT_VERSION,
            decodedLimit = PushProtocol.MAX_OBJECT_DECODED_BYTES,
        )
        assertEquals(RAW_IMU_SHA, imuBatch.contentSha256)
        assertEquals(RAW_IMU_BATCH_ID, imuBatch.batchId)
        assertEquals(RAW_IMU_OBJECT_ID, imuBatch.objectId)

        val imuWindowRows = (0 until 3601).map { offset ->
            val ts = 1_700_000_000L + offset
            PushBinaryRow.RawImuSession(PushRawImuRecord(ts, ts, imuColumns(offset.toShort())))
        }
        val windowBatch = PushProtocol.binaryObjectBatch(
            PushBinaryTable.RAW_IMU_SESSION, SOURCE_A, "strap-a", null, imuWindowRows,
            protocolVersion = PushProtocol.OBJECT_VERSION,
            decodedLimit = PushProtocol.MAX_OBJECT_DECODED_BYTES,
        )
        assertEquals(3600, windowBatch.sampleCount)

        val ppgBurstRow = PushPpgWaveformRecord(10, 100, 2, byteArrayOf(0x01, 0x02))
        val ppgBurstDecoded = PushBinaryCodec.pack(PushBinaryTable.PPG_WAVEFORM_SAMPLE, listOf(PushBinaryRow.PpgWaveform(ppgBurstRow)))
        assertEquals(PPG_BURST_PACK_HEX, ppgBurstDecoded.joinToString("") { "%02x".format(it) })
        val ppgBurstBatch = PushProtocol.binaryObjectBatch(
            PushBinaryTable.PPG_WAVEFORM_SAMPLE, SOURCE_A, "strap-a", null, listOf(PushBinaryRow.PpgWaveform(ppgBurstRow)),
            protocolVersion = PushProtocol.OBJECT_VERSION,
            decodedLimit = PushProtocol.MAX_OBJECT_DECODED_BYTES,
        )
        assertEquals(PPG_BURST_SHA, ppgBurstBatch.contentSha256)
        assertEquals(PPG_BURST_BATCH_ID, ppgBurstBatch.batchId)
        assertEquals(PPG_BURST_OBJECT_ID, ppgBurstBatch.objectId)

        val v18Row = PushV18AuxRecord(1, 10, byteArrayOf(0xAB.toByte()))
        val v18Decoded = PushBinaryCodec.pack(PushBinaryTable.V18_AUX_SAMPLE, listOf(PushBinaryRow.V18Aux(v18Row)))
        assertEquals(V18_PACK_HEX, v18Decoded.joinToString("") { "%02x".format(it) })
        val v18Batch = PushProtocol.binaryObjectBatch(
            PushBinaryTable.V18_AUX_SAMPLE, SOURCE_A, "strap", null, listOf(PushBinaryRow.V18Aux(v18Row)),
            protocolVersion = PushProtocol.OBJECT_VERSION,
            decodedLimit = PushProtocol.MAX_OBJECT_DECODED_BYTES,
        )
        assertEquals(V18_SHA, v18Batch.contentSha256)
        assertEquals(V18_BATCH_ID, v18Batch.batchId)
        assertEquals(V18_OBJECT_ID, v18Batch.objectId)

        val rawBatchRow = PushRawBatchRecord(
            rowId = 1,
            batchId = "batch-1",
            capturedAt = 100,
            deviceClockRef = 90,
            wallClockRef = 100,
            startTs = 100,
            endTs = 200,
            frameCount = 2,
            byteSize = 4,
            framesBlob = byteArrayOf(0x01, 0x02, 0x03, 0x04),
        )
        val rawBatchDecoded = PushBinaryCodec.pack(PushBinaryTable.RAW_BATCH, listOf(PushBinaryRow.RawBatch(rawBatchRow)))
        assertEquals(RAW_BATCH_PACK_HEX, rawBatchDecoded.joinToString("") { "%02x".format(it) })
        val rawBatchBatch = PushProtocol.binaryObjectBatch(
            PushBinaryTable.RAW_BATCH, SOURCE_A, "strap-a", null, listOf(PushBinaryRow.RawBatch(rawBatchRow)),
            protocolVersion = PushProtocol.OBJECT_VERSION,
            decodedLimit = PushProtocol.MAX_OBJECT_DECODED_BYTES,
        )
        assertEquals(RAW_BATCH_SHA, rawBatchBatch.contentSha256)
        assertEquals(RAW_BATCH_BATCH_ID, rawBatchBatch.batchId)
        assertEquals(RAW_BATCH_OBJECT_ID, rawBatchBatch.objectId)
    }

    private fun imuColumns(seed: Short): ByteArray {
        val data = ByteArray(PushBinaryCodec.IMU_RECORD_PAYLOAD_BYTES)
        for (index in 0 until PushBinaryCodec.IMU_COLUMNS_PER_RECORD) {
            val value = (seed + index.toShort()).toInt()
            data[index * 2] = (value and 0xff).toByte()
            data[index * 2 + 1] = ((value shr 8) and 0xff).toByte()
        }
        return data
    }

    private companion object {
        const val PPG_PACK_HEX =
            "4e5042310101020000000a00000000000000640000000000000001020000000200000001020b000000000000006500000000000000000100000003"
        const val PPG_CONTENT_SHA256 = "c87f354599322e01d2dcc548661ee24e10e4b3b5ef4e8471b348e23c6eca3950"
        const val PPG_BATCH_ID = "1da4e0a1-ef56-54a9-b787-0c6f9fbf7dde"
        const val PPG_OBJECT_ID = "4d578bf9-6c88-56f0-bc81-adc9e0edf06b"
        const val V18_END_FINGERPRINT = "fa1f331f9fb9d63ac32717818b9c0544a12fdfc5a2d5976d37012d34f5dcc067"
        const val PPG_NO_BURST_PACK_HEX = "4e5042310101010000000500000000000000320000000000000000010000000a"
        const val PPG_NO_BURST_SHA = "7a4521405729fb0e7ce3c7a8d63c8dad7c2372c7a9738b4eec05fa86fcfb9e8d"
        const val PPG_NO_BURST_BATCH_ID = "ef297f52-8888-5262-af98-0ba35b3421be"
        const val PPG_NO_BURST_OBJECT_ID = "39c2fdd4-c580-5360-b924-fb42d414fda7"
        const val RAW_IMU_PACK_HEX =
            "4e50423101040100000000f153650000000000f1536500000000b0040000ffff00000100020003000400050006000700080009000a000b000c000d000e000f0010001100120013001400150016001700180019001a001b001c001d001e001f0020002100220023002400250026002700280029002a002b002c002d002e002f0030003100320033003400350036003700380039003a003b003c003d003e003f0040004100420043004400450046004700480049004a004b004c004d004e004f0050005100520053005400550056005700580059005a005b005c005d005e005f0060006100620063006400650066006700680069006a006b006c006d006e006f0070007100720073007400750076007700780079007a007b007c007d007e007f0080008100820083008400850086008700880089008a008b008c008d008e008f0090009100920093009400950096009700980099009a009b009c009d009e009f00a000a100a200a300a400a500a600a700a800a900aa00ab00ac00ad00ae00af00b000b100b200b300b400b500b600b700b800b900ba00bb00bc00bd00be00bf00c000c100c200c300c400c500c600c700c800c900ca00cb00cc00cd00ce00cf00d000d100d200d300d400d500d600d700d800d900da00db00dc00dd00de00df00e000e100e200e300e400e500e600e700e800e900ea00eb00ec00ed00ee00ef00f000f100f200f300f400f500f600f700f800f900fa00fb00fc00fd00fe00ff0000010101020103010401050106010701080109010a010b010c010d010e010f0110011101120113011401150116011701180119011a011b011c011d011e011f0120012101220123012401250126012701280129012a012b012c012d012e012f0130013101320133013401350136013701380139013a013b013c013d013e013f0140014101420143014401450146014701480149014a014b014c014d014e014f0150015101520153015401550156015701580159015a015b015c015d015e015f0160016101620163016401650166016701680169016a016b016c016d016e016f0170017101720173017401750176017701780179017a017b017c017d017e017f0180018101820183018401850186018701880189018a018b018c018d018e018f0190019101920193019401950196019701980199019a019b019c019d019e019f01a001a101a201a301a401a501a601a701a801a901aa01ab01ac01ad01ae01af01b001b101b201b301b401b501b601b701b801b901ba01bb01bc01bd01be01bf01c001c101c201c301c401c501c601c701c801c901ca01cb01cc01cd01ce01cf01d001d101d201d301d401d501d601d701d801d901da01db01dc01dd01de01df01e001e101e201e301e401e501e601e701e801e901ea01eb01ec01ed01ee01ef01f001f101f201f301f401f501f601f701f801f901fa01fb01fc01fd01fe01ff0100020102020203020402050206020702080209020a020b020c020d020e020f0210021102120213021402150216021702180219021a021b021c021d021e021f0220022102220223022402250226022702280229022a022b022c022d022e022f0230023102320233023402350236023702380239023a023b023c023d023e023f0240024102420243024402450246024702480249024a024b024c024d024e024f025002510252025302540255025602"
        const val RAW_IMU_SHA = "ab4f2f112a7a6838316e017665d70a5c7fdbfd97b575c41c537a853cc3ac78bb"
        const val RAW_IMU_BATCH_ID = "ebc28c54-617a-550c-a316-8251b264e688"
        const val RAW_IMU_OBJECT_ID = "761fc0f5-7d98-5b17-ab49-5aa566447568"
        const val PPG_BURST_PACK_HEX =
            "4e5042310101010000000a0000000000000064000000000000000102000000020000000102"
        const val PPG_BURST_SHA = "97202e61885a87bcd72a78dff3be4d5273d1b4910b752cc007453e45dc62d3b9"
        const val PPG_BURST_BATCH_ID = "b68c8c9e-c055-5326-93a2-f3462f171621"
        const val PPG_BURST_OBJECT_ID = "9f16be5d-d1cd-56ca-9f7e-39105c5562c0"
        const val V18_PACK_HEX = "4e50423101020100000001000000000000000a0000000000000001000000ab"
        const val V18_SHA = "74fa28c092a172385f99eacb2826660ff7c47afbe89b1197273aca6176f0bb08"
        const val V18_BATCH_ID = "4a3f3494-07bc-52f1-baa0-030b3996ffee"
        const val V18_OBJECT_ID = "07982003-53ce-55da-ab08-89c961555278"
        const val RAW_BATCH_PACK_HEX =
            "4e5042310103070062617463682d3164000000000000005a0000000000000064000000000000006400000000000000c80000000000000002000000040000000400000001020304"
        const val RAW_BATCH_SHA = "cc0e6daf0ff9d5696767968a9faef4c031368bf8a5efdd490520517a34fef749"
        const val RAW_BATCH_BATCH_ID = "ed3d5ac8-09af-529d-a7a1-b6a56abef5bb"
        const val RAW_BATCH_OBJECT_ID = "22cc7400-3e75-5ed5-bc24-3875d185de70"
    }
}
