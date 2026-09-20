package com.noop.push

/** Protocol 1.2 adds the direct-to-bucket object lane and file-backed rawImuSession. */
object PushRegistryV1_2 {
    val additionalBinaryStreams: Set<String> = setOf("rawImuSession")
    val binaryStreams: Set<String> = PushRegistryV1_1.binaryStreams + additionalBinaryStreams
    val streamNames: Set<String> = PushRegistryV1_1.streamNames + additionalBinaryStreams
}

/** Protocol 1.1 extends v1.0 with every shipped table in cloud_ingestion_registry.json. */
object PushRegistryV1_1 {
    val binaryStreams: Set<String> = setOf("ppgWaveformSample", "v18AuxSample", "rawBatch")
    val streamNames: Set<String> = setOf(
        "hrSample", "rrInterval", "event", "battery", "spo2Sample", "skinTempSample", "respSample",
        "gravitySample", "dailyMetric", "sleepSession", "workout", "journal", "stepSample",
        "sleepStateSample", "ppgHrSample", "appleStepHour", "ouraRaw", "coachMessage", "metricSeries",
        "appleDaily", "scoreInputProvenance", "labMarker", "liveSession", "rrPacketProvenance", "standardHRReceipt",
    ) + binaryStreams
}
