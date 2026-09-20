/// Pure push wire registry and protocol constants. No GRDB, no URLSession.
public enum PushProtocolVersion: String, Sendable {
    case v1_0 = "1.0"
    case v1_1 = "1.1"
    case v1_2 = "1.2"
}

public enum PushDelivery: String, Sendable {
    case append
    case replaceWindow = "replace_window"
    case binaryObject = "binary_object"
}

public struct PushStreamSpec: Sendable {
    public let wireName: String
    public let delivery: PushDelivery
    public let keyColumns: [String]
    public let dataColumns: [String]
    public let windowSelector: String?

    public init(
        wireName: String,
        delivery: PushDelivery,
        keyColumns: [String],
        dataColumns: [String],
        windowSelector: String? = nil
    ) {
        self.wireName = wireName
        self.delivery = delivery
        self.keyColumns = keyColumns
        self.dataColumns = dataColumns
        self.windowSelector = windowSelector
    }
}

/// Closed registry for protocol 1.0 (upstream Experimental subset).
public enum PushRegistryV1 {
    public static let streams: [PushStreamSpec] = [
        PushStreamSpec(wireName: "hrSample", delivery: .append, keyColumns: ["ts"], dataColumns: ["bpm"]),
        PushStreamSpec(wireName: "rrInterval", delivery: .append, keyColumns: ["ts", "rrMs", "seq"],
                       dataColumns: ["ord", "srcChannel", "tsSuspect"]),
        PushStreamSpec(wireName: "event", delivery: .append, keyColumns: ["ts", "kind"], dataColumns: ["payloadJSON"]),
        PushStreamSpec(wireName: "battery", delivery: .append, keyColumns: ["ts"],
                       dataColumns: ["soc", "mv", "charging"]),
        PushStreamSpec(wireName: "spo2Sample", delivery: .append, keyColumns: ["ts"], dataColumns: ["red", "ir"]),
        PushStreamSpec(wireName: "skinTempSample", delivery: .append, keyColumns: ["ts"],
                       dataColumns: ["raw", "aux1Raw", "aux2Raw"]),
        PushStreamSpec(wireName: "respSample", delivery: .append, keyColumns: ["ts"], dataColumns: ["raw"]),
        PushStreamSpec(wireName: "gravitySample", delivery: .append, keyColumns: ["ts"],
                       dataColumns: ["x", "y", "z", "dynAccel"]),
        PushStreamSpec(wireName: "dailyMetric", delivery: .replaceWindow, keyColumns: ["day"],
                       dataColumns: [
                           "totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances",
                           "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct",
                           "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir",
                       ], windowSelector: "day"),
        PushStreamSpec(wireName: "sleepSession", delivery: .replaceWindow, keyColumns: ["startTs"],
                       dataColumns: [
                           "endTs", "efficiency", "restingHr", "avgHrv", "stagesJSON", "userEdited",
                           "startTsAdjusted", "motionJSON", "sleepStateJSON", "stagingSparse",
                       ], windowSelector: "startTs"),
        PushStreamSpec(wireName: "workout", delivery: .replaceWindow, keyColumns: ["startTs", "sport"],
                       dataColumns: [
                           "endTs", "source", "durationS", "energyKcal", "avgHr", "maxHr", "strain",
                           "distanceM", "zonesJSON", "notes", "routePolyline", "steps",
                       ], windowSelector: "startTs"),
        PushStreamSpec(wireName: "journal", delivery: .replaceWindow, keyColumns: ["day", "question"],
                       dataColumns: ["answeredYes", "notes", "numericValue"], windowSelector: "day"),
    ]

    public static let streamNames: Set<String> = Set(streams.map(\.wireName))
}

/// Protocol 1.1 extends v1.0 with every shipped table in `cloud_ingestion_registry.json`.
public enum PushRegistryV1_1 {
    public static let additionalStreams: [PushStreamSpec] = [
        PushStreamSpec(wireName: "standardHRReceipt", delivery: .append, keyColumns: ["receiptId"],
                       dataColumns: ["ts", "sessionId", "notificationOrdinal", "receivedUnixMs",
                                     "receivedMonotonicNs", "rawHex", "schemaVersion", "clockVersion"]),
        PushStreamSpec(wireName: "rrPacketProvenance", delivery: .append, keyColumns: ["packetId"],
                       dataColumns: [
                           "ts", "sensorTs", "recordIndex", "rawHex", "srcChannel", "schemaVersion",
                           "decoderVersion", "clockVersion", "timestampPrecisionSeconds",
                           "clockOffsetSeconds", "declaredCount",
                       ]),
        PushStreamSpec(wireName: "stepSample", delivery: .append, keyColumns: ["ts"],
                       dataColumns: ["counter", "activityClass"]),
        PushStreamSpec(wireName: "sleepStateSample", delivery: .append, keyColumns: ["ts"],
                       dataColumns: ["state", "rawByte"]),
        PushStreamSpec(wireName: "ppgHrSample", delivery: .append, keyColumns: ["ts"],
                       dataColumns: ["bpm", "conf"]),
        PushStreamSpec(wireName: "appleStepHour", delivery: .append, keyColumns: ["ts"], dataColumns: ["steps"]),
        PushStreamSpec(wireName: "ouraRaw", delivery: .append, keyColumns: ["endpoint", "documentId"],
                       dataColumns: ["day", "payloadJSON", "fetchedAt"]),
        PushStreamSpec(wireName: "coachMessage", delivery: .append, keyColumns: ["id"],
                       dataColumns: ["role", "text", "provider", "createdAt", "orderIndex"]),
        PushStreamSpec(wireName: "metricSeries", delivery: .replaceWindow, keyColumns: ["day", "key"],
                       dataColumns: ["value"], windowSelector: "day"),
        PushStreamSpec(wireName: "appleDaily", delivery: .replaceWindow, keyColumns: ["day"],
                       dataColumns: [
                           "steps", "activeKcal", "basalKcal", "vo2max", "avgHr", "maxHr", "walkingHr", "weightKg",
                       ], windowSelector: "day"),
        PushStreamSpec(wireName: "scoreInputProvenance", delivery: .replaceWindow, keyColumns: ["day", "key"],
                       dataColumns: ["sourceId"], windowSelector: "day"),
        PushStreamSpec(wireName: "labMarker", delivery: .replaceWindow, keyColumns: ["id"],
                       dataColumns: [
                           "markerKey", "category", "day", "takenAt", "value", "valueText", "unit", "source", "note",
                           "referenceText",
                       ], windowSelector: "day"),
        PushStreamSpec(wireName: "liveSession", delivery: .replaceWindow, keyColumns: ["startTs"],
                       dataColumns: [
                           "endTs", "chargeAtStart", "floorBpm", "ceilingBpm", "inBandSec", "belowSec", "aboveSec",
                           "pushCount", "easeCount", "hrSource",
                       ], windowSelector: "startTs"),
    ]

    public static let binaryStreams: Set<String> = ["ppgWaveformSample", "v18AuxSample", "rawBatch"]

    public static var streams: [PushStreamSpec] {
        var daily = PushRegistryV1.streams.first { $0.wireName == "dailyMetric" }!
        daily = PushStreamSpec(
            wireName: daily.wireName,
            delivery: daily.delivery,
            keyColumns: daily.keyColumns,
            dataColumns: daily.dataColumns + ["avgSdnn", "skinTempC", "sleepHrOnly"],
            windowSelector: daily.windowSelector
        )
        return PushRegistryV1.streams.filter { $0.wireName != "dailyMetric" } + [daily] + additionalStreams
    }

    public static let streamNames: Set<String> = Set(streams.map(\.wireName)).union(binaryStreams)
}

/// Protocol 1.2 adds the direct-to-bucket object lane and the file-backed 100 Hz IMU stream.
/// NDJSON and mutable streams are unchanged from 1.1; only the binary set grows.
public enum PushRegistryV1_2 {
    public static let additionalBinaryStreams: Set<String> = ["rawImuSession"]
    public static let binaryStreams: Set<String> = PushRegistryV1_1.binaryStreams.union(additionalBinaryStreams)

    public static var streams: [PushStreamSpec] { PushRegistryV1_1.streams }

    public static let streamNames: Set<String> = Set(PushRegistryV1_1.streams.map(\.wireName)).union(binaryStreams)
}

public enum PushProtocolLimits {
    public static let maxRecords = 5_000
    public static let maxBodyBytes = 4 * 1024 * 1024
    public static let maxWireBodyBytes = maxBodyBytes + 64 * 1024
    public static let maxAckBytes = 16 * 1024
    /// A rolling window may be multipart, but client memory use is fail-closed.
    public static let maxMutableSnapshotRecords = 1_000
    public static let maxMutableSnapshotEncodedBytes = 2 * 1024 * 1024
    /// Object lane (1.2): decoded NPB1 payload cap. A one-hour rawImuSession window is ~4.4 MiB,
    /// so the inline 4 MiB limit does not apply to objects; 64 MiB leaves headroom for sparse-ts
    /// windows while keeping client memory fail-closed.
    public static let maxObjectDecodedBytes = 64 * 1024 * 1024
    /// Wire cap for a compressed object. The receiver advertises its own ceiling (256 MiB) in the
    /// capabilities `objectLane` block; this is the local sanity bound, not the negotiated one.
    public static let maxObjectWireBytes = 256 * 1024 * 1024 + 64 * 1024
    /// rawImuSession objects span at most one hour of signal so a failed upload re-drives a
    /// bounded window and the coverage index stays legible per hour.
    public static let maxImuObjectWindowSeconds: Int64 = 3_600
}
