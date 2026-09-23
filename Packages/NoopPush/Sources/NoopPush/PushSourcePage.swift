import Foundation

public enum PushSourceReadError: Error, Sendable, Equatable {
    case deferred
    case requiresCompatibleEncoding
}

public struct PushPreparationLane: Sendable {
    public let sourceID: String
    public let table: String
    public let deviceID: String
    public init(sourceID: String, table: String, deviceID: String) {
        self.sourceID = sourceID; self.table = table; self.deviceID = deviceID
    }
}

public struct PushDeviceDiscovery: Sendable {
    public let deviceIDs: [String]
    public let isComplete: Bool
    public init(deviceIDs: [String], isComplete: Bool) { self.deviceIDs = deviceIDs; self.isComplete = isComplete }
}

public struct PushAppendPage: Sendable {
    public let rows: [PushAppendRecord]
    public let hasMore: Bool
    public init(rows: [PushAppendRecord], hasMore: Bool) { self.rows = rows; self.hasMore = hasMore }
}

public struct PushBinaryPage: Sendable {
    public let rows: [PushBinaryRow]
    public let hasMore: Bool
    public init(rows: [PushBinaryRow], hasMore: Bool) { self.rows = rows; self.hasMore = hasMore }
}

/// Receiver-scoped consumption frontier, captured before source reads and saved only after receipt.
public struct PushMutableFrontier: Codable, Sendable, Equatable {
    public let revision: Int64
    public let key: String
    public let calendarSignature: String
    public init(revision: Int64, key: String, calendarSignature: String) {
        self.revision = revision; self.key = key; self.calendarSignature = calendarSignature
    }
}
public struct PushMutableDirtyRange: Sendable {
    public let revision: Int64
    public let key: String
    public let fromDay: String
    public let toDay: String
    public init(revision: Int64, key: String, fromDay: String, toDay: String) {
        self.revision = revision; self.key = key; self.fromDay = fromDay; self.toDay = toDay
    }
}
public struct PushMutableDirtyPage: Sendable {
    public let ranges: [PushMutableDirtyRange]
    public let hasMore: Bool
    public init(ranges: [PushMutableDirtyRange], hasMore: Bool) { self.ranges = ranges; self.hasMore = hasMore }
}

public struct PushSourceReadLimits: Sendable {
    public let maximumDecodedBytes: Int
    public let protocolVersion: String
    public let shouldContinue: @Sendable () -> Bool
    public init(maximumDecodedBytes: Int, protocolVersion: String,
                shouldContinue: @escaping @Sendable () -> Bool) {
        self.maximumDecodedBytes = maximumDecodedBytes; self.protocolVersion = protocolVersion
        self.shouldContinue = shouldContinue
    }
}

public extension PushSnapshotSource {
    func discoverDevices(capabilities: PushCapabilities) async throws -> PushDeviceDiscovery {
        .init(deviceIDs: try await knownDeviceIds(capabilities: capabilities), isComplete: true)
    }
    /// Legacy adapters have no timestamp-indexed fresh lane. Never turn an unbounded scan into one.
    func freshAppendPage(table: PushAppendTable, deviceId: String, afterRowId: Int64, sinceTs: Int64, throughTs: Int64,
                         limit: Int, limits: PushSourceReadLimits) async throws -> PushAppendPage {
        .init(rows: [], hasMore: false)
    }
    func mutableDirtyRanges(table: PushMutableTable, deviceId: String, afterRevision: Int64,
                            afterKey: String, limit: Int, calendar: Calendar) async throws -> PushMutableDirtyPage? { nil }
    func appendPage(table: PushAppendTable, deviceId: String, afterRowId: Int64,
                    limit: Int, limits: PushSourceReadLimits) async throws -> PushAppendPage {
        guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
        return .init(rows: try await appendRows(table: table, deviceId: deviceId, afterRowId: afterRowId, limit: limit), hasMore: false)
    }
    func appendFingerprintAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> String? {
        guard let row = try await appendRecordAt(table: table, deviceId: deviceId, rowId: rowId) else { return nil }
        return try PushProtocol.keyFingerprint(table: table, deviceId: deviceId, key: row.key)
    }
    func binaryFingerprintAt(table: PushBinaryTable, deviceId: String, rowId: Int64,
                             protocolVersion: String) async throws -> String? {
        guard let row = try await binaryRecordAt(table: table, deviceId: deviceId, rowId: rowId) else { return nil }
        return try PushProtocol.binaryKeyFingerprint(table: table, deviceId: deviceId, row: row,
            v18IdentityV2: protocolVersion == PushProtocol.auxiliaryIdentityVersion)
    }

    func binaryPage(table: PushBinaryTable, deviceId: String, afterRowId: Int64,
                    limit: Int, limits: PushSourceReadLimits) async throws -> PushBinaryPage {
        guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
        let rows = try await binaryRows(table: table, deviceId: deviceId, afterRowId: afterRowId, limit: limit)
        var count = 0, size = PushBinaryCodec.packedHeaderSize(for: table)
        for row in rows {
            guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
            let bytes = try PushBinaryCodec.packedRowSize(row,
                ppgIdentityV2: PushProtocol.hasPPGIdentity(limits.protocolVersion),
                v18IdentityV2: limits.protocolVersion == PushProtocol.auxiliaryIdentityVersion)
            if bytes > limits.maximumDecodedBytes - size {
                if count == 0 { throw PushSourceReadError.requiresCompatibleEncoding }
                break
            }
            size += bytes; count += 1
            if table == .rawBatch { break }
        }
        return .init(rows: Array(rows.prefix(count)), hasMore: count < rows.count)
    }
}

public extension PushTransport {
    func beginBinaryPreparation(maximumWireBytes: Int) async throws -> PushBinaryPreparation? { nil }
    func finishBinaryPreparation(_ preparation: PushBinaryPreparation) async throws {}
    func uploadObject(_ intent: PushObjectIntent, file: PushImmutablePayloadFile) async throws {
        try await uploadObject(intent, body: file.materialized())
    }
}
