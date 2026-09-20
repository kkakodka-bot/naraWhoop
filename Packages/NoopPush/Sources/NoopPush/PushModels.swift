import Foundation

public protocol PushTable: Sendable {
    var wireName: String { get }
}

public enum PushAppendTable: String, CaseIterable, PushTable, Sendable {
    case hrSample
    case rrInterval
    case rrPacketProvenance
    case standardHRReceipt
    case event
    case battery
    case spo2Sample
    case skinTempSample
    case respSample
    case gravitySample

    public var wireName: String { rawValue }
}

public enum PushMutableTable: String, CaseIterable, PushTable, Sendable {
    case dailyMetric
    case sleepSession
    case workout
    case journal

    public var wireName: String { rawValue }
}

public enum PushBinaryTable: String, CaseIterable, PushTable, Sendable {
    case ppgWaveformSample
    case v18AuxSample
    case rawBatch
    case rawImuSession

    public var wireName: String { rawValue }

    public var contentEncoding: String {
        switch self {
        case .ppgWaveformSample, .v18AuxSample: return "gzip"
        case .rawBatch, .rawImuSession: return "zstd"
        }
    }
}

public struct PushPpgWaveformRecord: Sendable {
    public let rowId: Int64
    public let ts: Int64
    public let burstIndex: Int32?
    public let samples: Data
    public let recordIndex: Int64?

    public init(rowId: Int64, ts: Int64, burstIndex: Int32?, samples: Data, recordIndex: Int64? = nil) {
        precondition(rowId > 0)
        self.rowId = rowId
        self.ts = ts
        self.burstIndex = burstIndex
        self.samples = samples
        self.recordIndex = recordIndex
    }
}

public struct PushV18AuxRecord: Sendable {
    public let rowId: Int64
    public let ts: Int64
    public let fields: Data

    public init(rowId: Int64, ts: Int64, fields: Data) {
        precondition(rowId > 0)
        self.rowId = rowId
        self.ts = ts
        self.fields = fields
    }
}

public struct PushRawBatchRecord: Sendable {
    public let rowId: Int64
    public let batchId: String
    public let capturedAt: Int64
    public let deviceClockRef: Int64
    public let wallClockRef: Int64
    public let startTs: Int64
    public let endTs: Int64
    public let frameCount: Int32
    public let byteSize: Int32
    public let framesBlob: Data

    public init(
        rowId: Int64,
        batchId: String,
        capturedAt: Int64,
        deviceClockRef: Int64,
        wallClockRef: Int64,
        startTs: Int64,
        endTs: Int64,
        frameCount: Int32,
        byteSize: Int32,
        framesBlob: Data
    ) {
        precondition(rowId > 0)
        self.rowId = rowId
        self.batchId = batchId
        self.capturedAt = capturedAt
        self.deviceClockRef = deviceClockRef
        self.wallClockRef = wallClockRef
        self.startTs = startTs
        self.endTs = endTs
        self.frameCount = frameCount
        self.byteSize = byteSize
        self.framesBlob = framesBlob
    }
}

/// One second of 100 Hz six-axis IMU: 600 little-endian i16 columns (100 samples per axis,
/// axis-major) exactly as laid out by `ImuSessionFileStore`. `rowId` mirrors `ts` (epoch seconds)
/// because the file store keys records by timestamp, not by SQLite rowid.
public struct PushRawImuRecord: Sendable {
    public let rowId: Int64
    public let ts: Int64
    public let columns: Data

    public init(rowId: Int64, ts: Int64, columns: Data) {
        precondition(rowId > 0)
        self.rowId = rowId
        self.ts = ts
        self.columns = columns
    }
}

public enum PushBinaryRow: Sendable {
    case ppgWaveform(PushPpgWaveformRecord)
    case v18Aux(PushV18AuxRecord)
    case rawBatch(PushRawBatchRecord)
    case rawImuSession(PushRawImuRecord)
}

public struct PushBinaryBatch: Sendable {
    public let protocolVersion: String
    public let batchId: String
    public let sourceId: String
    public let table: PushBinaryTable
    public let deviceId: String
    public let objectId: String
    public let startTs: Int64
    public let endTs: Int64
    public let sampleCount: Int
    public let uncompressedBytes: Int
    public let contentSha256: String
    public let contentEncoding: String
    public let endCursor: PushCursor?
    public let manifestJSON: Data
    public let payload: Data

    public var wireName: String { table.wireName }
}

public struct PushAppendRecord: Sendable {
    public let rowId: Int64
    public let key: [String: PushJSONValue]
    public let data: [String: PushJSONValue]

    public init(rowId: Int64, key: [String: PushJSONValue], data: [String: PushJSONValue]) {
        precondition(rowId > 0, "SQLite rowid must be positive")
        precondition(!key.isEmpty, "natural key must not be empty")
        self.rowId = rowId
        self.key = key
        self.data = data
    }
}

public struct PushMutableRecord: Sendable {
    public let key: [String: PushJSONValue]
    public let data: [String: PushJSONValue]

    public init(key: [String: PushJSONValue], data: [String: PushJSONValue]) {
        precondition(!key.isEmpty, "natural key must not be empty")
        self.key = key
        self.data = data
    }
}

public struct PushWindow: Sendable {
    public let fromDay: String
    public let toDay: String
    public let startTsInclusive: Int64
    public let endTsExclusive: Int64

    public init(fromDay: String, toDay: String, startTsInclusive: Int64, endTsExclusive: Int64) {
        self.fromDay = fromDay
        self.toDay = toDay
        self.startTsInclusive = startTsInclusive
        self.endTsExclusive = endTsExclusive
    }

    public static func ending(today: Date, calendar: Calendar = .current) -> PushWindow {
        days(from: calendar.date(byAdding: .day, value: -13, to: today) ?? today, to: today, calendar: calendar)
    }

    public static func days(from: Date, to: Date, calendar: Calendar = .current) -> PushWindow {
        precondition(to >= from)
        let formatter = Self.dayFormatter
        let fromDay = formatter.string(from: from)
        let toDay = formatter.string(from: to)
        let start = calendar.startOfDay(for: from).timeIntervalSince1970
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: to))?
            .timeIntervalSince1970 ?? start
        return PushWindow(
            fromDay: fromDay,
            toDay: toDay,
            startTsInclusive: Int64(start),
            endTsExclusive: Int64(end)
        )
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}

public struct PushCursor: Sendable, Equatable {
    public let rowId: Int64
    public let naturalKeyFingerprint: String

    public init(rowId: Int64, naturalKeyFingerprint: String) {
        self.rowId = rowId
        self.naturalKeyFingerprint = naturalKeyFingerprint
    }
}

public struct PushWindowProgress: Sendable {
    public let window: PushWindow
    public let batchId: String
    public let dayHashes: [String: String]

    public init(window: PushWindow, batchId: String, dayHashes: [String: String] = [:]) {
        self.window = window
        self.batchId = batchId
        self.dayHashes = dayHashes
    }
}

public struct PushBatch: Sendable {
    public let protocolVersion: String
    public let batchId: String
    public let sourceId: String
    public let table: any PushTable
    public let deviceId: String
    public let mode: String
    public let startCursor: PushCursor?
    public let endCursor: PushCursor?
    public let recordCount: Int
    public let window: PushWindow?
    public let replacementId: String?
    public let part: Int?
    public let parts: Int?
    public let body: Data

    public init(
        protocolVersion: String,
        batchId: String,
        sourceId: String,
        table: any PushTable,
        deviceId: String,
        mode: String,
        startCursor: PushCursor?,
        endCursor: PushCursor?,
        recordCount: Int,
        window: PushWindow?,
        replacementId: String? = nil,
        part: Int? = nil,
        parts: Int? = nil,
        body: Data
    ) {
        self.protocolVersion = protocolVersion
        self.batchId = batchId
        self.sourceId = sourceId
        self.table = table
        self.deviceId = deviceId
        self.mode = mode
        self.startCursor = startCursor
        self.endCursor = endCursor
        self.recordCount = recordCount
        self.window = window
        self.replacementId = replacementId
        self.part = part
        self.parts = parts
        self.body = body
    }
}

public struct PushTransportResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// The `objectLane` block of a 1.2 capabilities response: where object intents go, how large an
/// object may be, and which binary streams the receiver archives direct-to-bucket.
public struct PushObjectLane: Sendable, Equatable {
    public let endpoint: String
    public let maxObjectBytes: Int64
    public let urlTtlSec: Int64?
    public let streams: Set<PushBinaryTable>

    public init(endpoint: String, maxObjectBytes: Int64, urlTtlSec: Int64?, streams: Set<PushBinaryTable>) {
        self.endpoint = endpoint
        self.maxObjectBytes = maxObjectBytes
        self.urlTtlSec = urlTtlSec
        self.streams = streams
    }
}

/// The intent body posted to the object lane. `contentSha256` is over the UNCOMPRESSED payload;
/// the receiver decompresses the uploaded object and refuses a manifest whose digest does not match.
public struct PushObjectManifest: Sendable, Equatable {
    public let protocolVersion: String
    public let batchId: String
    public let sourceId: String
    public let deviceId: String
    public let stream: String
    public let objectId: String
    public let startTs: Int64
    public let endTs: Int64
    public let sampleCount: Int64
    public let uncompressedBytes: Int64
    public let compressedBytes: Int64
    public let contentSha256: String
    public let contentEncoding: String

    public init(batch: PushBinaryBatch) {
        self.protocolVersion = batch.protocolVersion
        self.batchId = batch.batchId
        self.sourceId = batch.sourceId
        self.deviceId = batch.deviceId
        self.stream = batch.table.wireName
        self.objectId = batch.objectId
        self.startTs = batch.startTs
        self.endTs = batch.endTs
        self.sampleCount = Int64(batch.sampleCount)
        self.uncompressedBytes = Int64(batch.uncompressedBytes)
        self.compressedBytes = Int64(batch.payload.count)
        self.contentSha256 = batch.contentSha256
        self.contentEncoding = batch.contentEncoding
    }

    /// Returns a copy with a fresh object id. Used after `object_id_conflict`: the id is burned
    /// server-side, so the same bytes are re-intented under a new one.
    public func replacingObjectId(_ newObjectId: String) -> PushObjectManifest {
        PushObjectManifest(
            protocolVersion: protocolVersion, batchId: batchId, sourceId: sourceId, deviceId: deviceId,
            stream: stream, objectId: newObjectId, startTs: startTs, endTs: endTs,
            sampleCount: sampleCount, uncompressedBytes: uncompressedBytes, compressedBytes: compressedBytes,
            contentSha256: contentSha256, contentEncoding: contentEncoding
        )
    }

    private init(
        protocolVersion: String, batchId: String, sourceId: String, deviceId: String, stream: String,
        objectId: String, startTs: Int64, endTs: Int64, sampleCount: Int64, uncompressedBytes: Int64,
        compressedBytes: Int64, contentSha256: String, contentEncoding: String
    ) {
        self.protocolVersion = protocolVersion
        self.batchId = batchId
        self.sourceId = sourceId
        self.deviceId = deviceId
        self.stream = stream
        self.objectId = objectId
        self.startTs = startTs
        self.endTs = endTs
        self.sampleCount = sampleCount
        self.uncompressedBytes = uncompressedBytes
        self.compressedBytes = compressedBytes
        self.contentSha256 = contentSha256
        self.contentEncoding = contentEncoding
    }

    public func encode() throws -> Data {
        let map: [String: PushJSONValue] = [
            "batchId": .string(batchId),
            "contentEncoding": .string(contentEncoding),
            "contentSha256": .string(contentSha256),
            "compressedBytes": .int(compressedBytes),
            "deviceId": .string(deviceId),
            "endTs": .int(endTs),
            "objectId": .string(objectId),
            "protocolVersion": .string(protocolVersion),
            "sampleCount": .int(sampleCount),
            "sourceId": .string(sourceId),
            "startTs": .int(startTs),
            "stream": .string(stream),
            "type": .string("binaryObject"),
            "uncompressedBytes": .int(uncompressedBytes),
        ]
        return Data(try PushProtocol.canonicalJsonMap(map).utf8)
    }
}

/// The receiver's answer to an intent: the minted object key and, unless the object is already
/// archived (`duplicate`), a presigned upload URL plus the exact headers the PUT must carry.
public struct PushObjectIntent: Sendable, Equatable {
    public let objectId: String
    public let objectKey: String
    public let uploadUrl: String?
    public let requiredHeaders: [String: String]
    public let expiresAt: String?
    public let duplicate: Bool

    public init(
        objectId: String, objectKey: String, uploadUrl: String?, requiredHeaders: [String: String],
        expiresAt: String?, duplicate: Bool
    ) {
        self.objectId = objectId
        self.objectKey = objectKey
        self.uploadUrl = uploadUrl
        self.requiredHeaders = requiredHeaders
        self.expiresAt = expiresAt
        self.duplicate = duplicate
    }
}

public struct PushObjectAck: Sendable, Equatable {
    public let objectId: String
    public let status: String
    public let objectKey: String
    public let duplicate: Bool

    public init(objectId: String, status: String, objectKey: String, duplicate: Bool) {
        self.objectId = objectId
        self.status = status
        self.objectKey = objectKey
        self.duplicate = duplicate
    }

    /// Local rows are released only when the receiver has the object and its digest verified.
    public var releasesLocalRows: Bool { status == "ready" || status == "verified" }
}

/// Bookkeeping for an interrupted object upload, persisted between intent and ack so a relaunch
/// resumes onto the same `objectKey` instead of minting a duplicate manifest row.
public struct PushInFlightObject: Sendable, Equatable {
    public let objectId: String
    public let objectKey: String
    public let contentSha256: String
    public let uploaded: Bool

    public init(objectId: String, objectKey: String, contentSha256: String, uploaded: Bool) {
        self.objectId = objectId
        self.objectKey = objectKey
        self.contentSha256 = contentSha256
        self.uploaded = uploaded
    }
}

public enum PushResult: Sendable {
    case accepted(batchId: String, recordCount: Int, hasMore: Bool, batchCount: Int = 1)
    case noData
    case rejected(reason: String, retryable: Bool, failure: PushFailure?)
}

public struct PushRunResult: Sendable {
    public let acceptedBatches: Int
    public let rejectedBatches: Int
    public let hasMoreAppendRows: Bool
    public let hasMoreBinaryRows: Bool
    public let acceptedRecords: Int
    public let hasRetryableFailure: Bool
    public let nextDeviceIndex: Int
    public let hasMoreDevices: Bool
    public let failure: PushFailure?

    public init(
        acceptedBatches: Int,
        rejectedBatches: Int,
        hasMoreAppendRows: Bool,
        hasMoreBinaryRows: Bool = false,
        acceptedRecords: Int = 0,
        hasRetryableFailure: Bool = false,
        nextDeviceIndex: Int = 0,
        hasMoreDevices: Bool = false,
        failure: PushFailure? = nil
    ) {
        self.acceptedBatches = acceptedBatches
        self.rejectedBatches = rejectedBatches
        self.hasMoreAppendRows = hasMoreAppendRows
        self.hasMoreBinaryRows = hasMoreBinaryRows
        self.acceptedRecords = acceptedRecords
        self.hasRetryableFailure = hasRetryableFailure
        self.nextDeviceIndex = nextDeviceIndex
        self.hasMoreDevices = hasMoreDevices
        self.failure = failure
    }
}

public protocol PushTransport: Sendable {
    func capabilities() async throws -> PushCapabilitiesResult
    func post(_ batch: PushBatch) async throws -> PushTransportResponse
    func postBinary(_ batch: PushBinaryBatch) async throws -> PushTransportResponse
    /// Object lane (protocol 1.2): mint an object key + presigned upload URL for a manifest.
    func createObjectIntent(_ manifest: PushObjectManifest, lane: PushObjectLane) async throws -> PushObjectIntent
    /// PUT the compressed payload straight to the bucket URL, carrying exactly `intent.requiredHeaders`.
    func uploadObject(_ intent: PushObjectIntent, body: Data) async throws
    /// Tell the receiver the bytes are at the bucket; it verifies size + digest and acks.
    func completeObject(objectId: String, lane: PushObjectLane) async throws -> PushObjectAck
}

public extension PushTransport {
    func createObjectIntent(_ manifest: PushObjectManifest, lane: PushObjectLane) async throws -> PushObjectIntent {
        throw PushTransportException(PushFailure(code: .localData))
    }

    func uploadObject(_ intent: PushObjectIntent, body: Data) async throws {
        throw PushTransportException(PushFailure(code: .localData))
    }

    func completeObject(objectId: String, lane: PushObjectLane) async throws -> PushObjectAck {
        throw PushTransportException(PushFailure(code: .localData))
    }
}

public protocol PushProgressStore: Sendable {
    func knownDeviceIds() async throws -> Set<String>
    func rememberDeviceId(_ deviceId: String) async throws
    func cursor(table: PushAppendTable, deviceId: String) async throws -> PushCursor?
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) async throws
    func binaryCursor(table: PushBinaryTable, deviceId: String) async throws -> PushCursor?
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) async throws
    func window(table: PushMutableTable, deviceId: String) async throws -> PushWindowProgress?
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) async throws
    /// The interrupted object upload for this stream, if any. `nil` means no resume is pending.
    func inFlightObject(table: PushBinaryTable, deviceId: String) async throws -> PushInFlightObject?
    func saveInFlightObject(table: PushBinaryTable, deviceId: String, object: PushInFlightObject?) async throws
}

public extension PushProgressStore {
    /// Stores predating the object lane have no in-flight state; the coordinator rebuilds and
    /// re-intents from scratch, which the receiver dedupes by object id.
    func inFlightObject(table: PushBinaryTable, deviceId: String) async throws -> PushInFlightObject? { nil }
    func saveInFlightObject(table: PushBinaryTable, deviceId: String, object: PushInFlightObject?) async throws {}
}

public protocol PushSnapshotSource: Sendable {
    func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String]
    func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord?
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord]
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord]
    func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) async throws -> PushBinaryRow?
    func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushBinaryRow]
    func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) async throws
}

/// JSON values permitted on the push wire.
public enum PushJSONValue: Sendable, Equatable {
    case null
    case string(String)
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case map([String: PushJSONValue])
    case array([PushJSONValue])

    public var int64Value: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let d) where d.rounded() == d && d >= Double(Int64.min) && d <= Double(Int64.max):
            return Int64(d)
        default: return nil
        }
    }
}
