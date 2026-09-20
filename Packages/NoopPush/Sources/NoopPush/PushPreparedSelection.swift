import Foundation

/// Local continuation format, not a new wire protocol. Decoding never rebuilds or recompresses a batch.
public struct PushPreparedSelection: Codable, Sendable {
    public static let formatVersion = 2
    public static let maximumParts = 64
    public static let maximumEncodedBytes = 768 * 1_048_576
    public let version: Int
    public let commit: PushSourceCommit
    private let inline: [Inline]
    private let binary: Binary?

    public var sourceID: String { binary?.manifest.sourceId ?? inline[0].sourceID }
    public var protocolVersion: String { binary?.manifest.protocolVersion ?? inline[0].protocolVersion }
    public var deviceID: String { commit.deviceID }
    public var batchIDs: [String] { commit.batchIDs }
    // Lightweight accessors for queue accounting. The value has already been validated at
    // construction/decoding; counting files must not repack every raw object on each receipt.
    public var objectManifest: PushObjectManifest? { binary?.manifest }
    public var objectPayload: Data? { binary?.payload }
    public var objectIntentBytes: Data? { binary?.intentJSON }
    public var inlineBodies: [Data] { inline.map(\.body) }

    public init(inline batches: [PushBatch], commit: PushSourceCommit) throws {
        version = Self.formatVersion; self.commit = commit
        inline = batches.map(Inline.init); binary = nil
        try validate()
    }

    public init(binary batch: PushBinaryBatch, rows: [PushBinaryRow], manifest: PushObjectManifest,
                lane: PushObjectLane, commit: PushSourceCommit) throws {
        version = Self.formatVersion; self.commit = commit; inline = []
        binary = try Binary(batch: batch, rows: rows, manifest: manifest, lane: lane)
        try validate()
    }

    public func restoredInlineBatches() throws -> [PushBatch] { try inline.map { try $0.restore() } }
    public func restoredObject() throws -> (batch: PushBinaryBatch, rows: [PushBinaryRow], manifest: PushObjectManifest, lane: PushObjectLane)? {
        try binary?.restore()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumEncodedBytes else { throw Self.invalid() }
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumEncodedBytes else { throw invalid() }
        return try JSONDecoder().decode(Self.self, from: bytes)
    }

    private enum CodingKeys: String, CodingKey { case version, commit, inline, binary }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else { throw Self.invalid() }
        commit = try c.decode(PushSourceCommit.self, forKey: .commit)
        inline = try c.decode([Inline].self, forKey: .inline)
        binary = try c.decodeIfPresent(Binary.self, forKey: .binary)
        try validate()
    }

    private func validate() throws {
        guard version == Self.formatVersion, !commit.batchIDs.isEmpty,
              Set(commit.batchIDs).count == commit.batchIDs.count,
              commit.batchIDs.allSatisfy(Self.uuid), !commit.deviceID.isEmpty,
              commit.deviceID.utf8.count <= 1024 else { throw Self.invalid() }
        if let binary {
            let restored = try binary.restore()
            let batch = restored.batch
            let rawIDs = restored.rows.compactMap { row -> String? in
                if case .rawBatch(let value) = row { return value.batchId }; return nil
            }
            guard inline.isEmpty, commit.kind == .binary, commit.table == batch.wireName,
                  commit.deviceID == batch.deviceId, commit.batchIDs == [batch.batchId],
                  commit.cursor == batch.endCursor, commit.window == nil,
                  commit.rawBatchIDs == rawIDs else { throw Self.invalid() }
            return
        }
        guard !inline.isEmpty, inline.count <= Self.maximumParts,
              commit.rawBatchIDs.isEmpty, inline.map(\.batchID) == commit.batchIDs else { throw Self.invalid() }
        let batches = try restoredInlineBatches()
        let first = batches[0]
        guard batches.allSatisfy({ $0.sourceId == first.sourceId && $0.deviceId == commit.deviceID
            && $0.table.wireName == commit.table && $0.protocolVersion == first.protocolVersion }) else { throw Self.invalid() }
        switch commit.kind {
        case .append:
            guard batches.count == 1, first.mode == "append", commit.cursor != nil,
                  commit.cursor == first.endCursor, commit.window == nil else { throw Self.invalid() }
        case .mutable:
            guard commit.cursor == nil, let progress = commit.window, let window = first.window,
                  progress.batchId == first.replacementId,
                  Self.validWindow(progress.window), Self.validWindow(window),
                  progress.window.fromDay <= window.fromDay, progress.window.toDay >= window.toDay,
                  progress.window.startTsInclusive <= window.startTsInclusive,
                  progress.window.endTsExclusive >= window.endTsExclusive,
                  !progress.dayHashes.isEmpty, progress.dayHashes.count <= 366,
                  progress.dayHashes.allSatisfy({ Self.day($0.key) != nil && Self.digest($0.value)
                    && $0.key >= progress.window.fromDay && $0.key <= progress.window.toDay }) else { throw Self.invalid() }
            let dayCount = Int(Self.day(progress.window.toDay)!.timeIntervalSince(Self.day(progress.window.fromDay)!) / 86_400) + 1
            guard dayCount == progress.dayHashes.count else { throw Self.invalid() }
            for (index, part) in batches.enumerated() {
                guard part.mode == "replace_window", part.part == index + 1, part.parts == batches.count,
                      part.replacementId == first.replacementId, let other = part.window,
                      Self.sameWindow(other, window) else { throw Self.invalid() }
            }
        case .binary: throw Self.invalid()
        }
    }

    private struct Inline: Codable, Sendable {
        let protocolVersion, batchID, sourceID, table, deviceID, mode: String
        let startCursor, endCursor: PushCursor?
        let recordCount: Int
        let window: PushWindow?
        let replacementID: String?
        let part, parts: Int?
        let body: Data
        let bodySHA256: String
        init(_ batch: PushBatch) {
            protocolVersion = batch.protocolVersion; batchID = batch.batchId; sourceID = batch.sourceId
            table = batch.table.wireName; deviceID = batch.deviceId; mode = batch.mode
            startCursor = batch.startCursor; endCursor = batch.endCursor; recordCount = batch.recordCount
            window = batch.window; replacementID = batch.replacementId; part = batch.part; parts = batch.parts
            body = batch.body; bodySHA256 = PushDurabilityReceipt.sha256(batch.body)
        }
        func restore() throws -> PushBatch {
            guard uuid(batchID), uuid(sourceID), supported(protocolVersion), !body.isEmpty,
                  body.count <= PushProtocolLimits.maxBodyBytes, body.last == 10,
                  PushDurabilityReceipt.sha256(body) == bodySHA256,
                  (0...PushProtocolLimits.maxRecords).contains(recordCount),
                  let newline = body.firstIndex(of: 10),
                  let header = try JSONSerialization.jsonObject(with: body[..<newline]) as? [String: Any],
                  header["type"] as? String == "batch", header["batchId"] as? String == batchID,
                  header["sourceId"] as? String == sourceID, header["deviceId"] as? String == deviceID,
                  header["stream"] as? String == table, header["delivery"] as? String == mode,
                  header["protocolVersion"] as? String == protocolVersion,
                  integer(header["recordCount"]) == Int64(recordCount),
                  body.reduce(0, { $0 + ($1 == 10 ? 1 : 0) }) == recordCount + 1,
                  cursorMatches(header["startCursor"], startCursor), cursorMatches(header["endCursor"], endCursor)
            else { throw invalid() }
            let type: any PushTable
            if mode == "append", let append = PushAppendTable(rawValue: table) {
                guard recordCount > 0, endCursor != nil, window == nil, replacementID == nil,
                      part == nil, parts == nil else { throw invalid() }
                type = append
            } else if mode == "replace_window", let mutable = PushMutableTable(rawValue: table) {
                guard let window, validWindow(window), let replacementID, uuid(replacementID),
                      let part, let parts, part > 0, part <= parts, parts <= maximumParts,
                      startCursor == nil, endCursor == nil,
                      let selector = header["window"] as? [String: Any],
                      selector["replacementId"] as? String == replacementID,
                      integer(selector["part"]) == Int64(part), integer(selector["parts"]) == Int64(parts) else { throw invalid() }
                if mutable == .dailyMetric || mutable == .journal {
                    guard selector["selector"] as? String == "day", selector["startInclusive"] as? String == window.fromDay,
                          let end = selector["endExclusive"] as? String, let date = day(window.toDay),
                          day(end) == date.addingTimeInterval(86_400) else { throw invalid() }
                } else {
                    guard selector["selector"] as? String == "startTs",
                          integer(selector["startInclusive"]) == window.startTsInclusive,
                          integer(selector["endExclusive"]) == window.endTsExclusive else { throw invalid() }
                }
                type = mutable
            } else { throw invalid() }
            return .init(protocolVersion: protocolVersion, batchId: batchID, sourceId: sourceID, table: type,
                deviceId: deviceID, mode: mode, startCursor: startCursor, endCursor: endCursor,
                recordCount: recordCount, window: window, replacementId: replacementID, part: part, parts: parts, body: body)
        }
    }

    private struct Binary: Codable, Sendable {
        let originalManifest, manifest: PushObjectManifest
        let endCursor: PushCursor?
        let manifestJSON, intentJSON, payload: Data
        let wireSHA256: String
        let rows: [Member]
        let lanePath: String
        let maxObjectBytes: Int64
        let urlTtlSec: Int64?
        let streams: [String]
        init(batch: PushBinaryBatch, rows: [PushBinaryRow], manifest: PushObjectManifest, lane: PushObjectLane) throws {
            originalManifest = .init(batch: batch); self.manifest = manifest; endCursor = batch.endCursor
            manifestJSON = batch.manifestJSON; payload = batch.payload
            intentJSON = try manifest.encode()
            wireSHA256 = PushDurabilityReceipt.sha256(batch.payload); self.rows = rows.map(Member.init)
            lanePath = lane.endpoint; maxObjectBytes = lane.maxObjectBytes; urlTtlSec = lane.urlTtlSec
            streams = lane.streams.map(\.rawValue).sorted()
        }
        func restore() throws -> (batch: PushBinaryBatch, rows: [PushBinaryRow], manifest: PushObjectManifest, lane: PushObjectLane) {
            guard rows.count > 0, rows.count <= PushProtocolLimits.maxRecords,
                  manifest == originalManifest.replacingObjectId(manifest.objectId), uuid(manifest.objectId),
                  intentJSON.count <= 8192, try JSONDecoder().decode(PushObjectManifest.self, from: intentJSON) == manifest,
                  (try JSONSerialization.jsonObject(with: intentJSON) as? [String: Any])?["type"] as? String == "binaryObject",
                  lanePath.hasPrefix("/"), !lanePath.hasPrefix("//"),
                  !lanePath.contains(".."), !lanePath.contains("?"), !lanePath.contains("#"),
                  lanePath.utf8.count <= 1024,
                  maxObjectBytes > 0, maxObjectBytes <= Int64(PushProtocolLimits.maxObjectWireBytes),
                  Int64(payload.count) <= maxObjectBytes else { throw invalid() }
            let tables = streams.compactMap(PushBinaryTable.init(rawValue:))
            guard tables.count == streams.count, Set(tables).count == tables.count,
                  streams.contains(manifest.stream) else { throw invalid() }
            let restoredRows = try rows.map { try $0.restore() }
            let batch = try PushBinaryBatch.restoring(manifest: originalManifest, endCursor: endCursor,
                manifestJSON: manifestJSON, payload: payload, wireSHA256: wireSHA256, rows: restoredRows)
            return (batch, restoredRows, manifest, .init(endpoint: lanePath, maxObjectBytes: maxObjectBytes,
                urlTtlSec: urlTtlSec, streams: Set(tables)))
        }
    }

    private enum Member: Codable, Sendable {
        case ppg(rowID: Int64, ts: Int64, burst: Int32?, record: Int64?, bytes: Data)
        case auxiliary(rowID: Int64, ts: Int64, record: Int64?, resource: String?, bytes: Data)
        case raw(rowID: Int64, batch: String, captured: Int64, deviceClock: Int64, wallClock: Int64,
                 start: Int64, end: Int64, frames: Int32, byteSize: Int32, bytes: Data)
        case imu(rowID: Int64, ts: Int64, bytes: Data)
        init(_ row: PushBinaryRow) {
            switch row {
            case .ppgWaveform(let r): self = .ppg(rowID: r.rowId, ts: r.ts, burst: r.burstIndex, record: r.recordIndex, bytes: r.samples)
            case .v18Aux(let r): self = .auxiliary(rowID: r.rowId, ts: r.ts, record: r.recordIndex, resource: r.resourceKey, bytes: r.fields)
            case .rawBatch(let r): self = .raw(rowID: r.rowId, batch: r.batchId, captured: r.capturedAt,
                deviceClock: r.deviceClockRef, wallClock: r.wallClockRef, start: r.startTs, end: r.endTs,
                frames: r.frameCount, byteSize: r.byteSize, bytes: r.framesBlob)
            case .rawImuSession(let r): self = .imu(rowID: r.rowId, ts: r.ts, bytes: r.columns)
            }
        }
        func restore() throws -> PushBinaryRow {
            switch self {
            case let .ppg(id, ts, burst, record, bytes):
                guard id > 0, bytes.count <= PushProtocolLimits.maxObjectDecodedBytes else { throw invalid() }
                return .ppgWaveform(.init(rowId: id, ts: ts, burstIndex: burst, samples: bytes, recordIndex: record))
            case let .auxiliary(id, ts, record, resource, bytes):
                guard id > 0, bytes.count <= PushProtocolLimits.maxObjectDecodedBytes,
                      resource.map({ !$0.isEmpty && $0.utf8.count <= 1024 }) ?? true else { throw invalid() }
                return .v18Aux(.init(rowId: id, ts: ts, fields: bytes, recordIndex: record, resourceKey: resource))
            case let .raw(id, batch, captured, clock, wall, start, end, frames, size, bytes):
                guard id > 0, !batch.isEmpty, batch.utf8.count <= 65535, frames >= 0, size >= 0,
                      bytes.count <= PushProtocolLimits.maxObjectDecodedBytes else { throw invalid() }
                return .rawBatch(.init(rowId: id, batchId: batch, capturedAt: captured, deviceClockRef: clock,
                    wallClockRef: wall, startTs: start, endTs: end, frameCount: frames, byteSize: size, framesBlob: bytes))
            case let .imu(id, ts, bytes):
                guard id > 0, bytes.count == PushBinaryCodec.imuRecordPayloadBytes else { throw invalid() }
                return .rawImuSession(.init(rowId: id, ts: ts, columns: bytes))
            }
        }
    }

    static func invalid() -> PushProtocolException { .init("invalid prepared selection") }
    static func uuid(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    static func digest(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func supported(_ value: String) -> Bool { PushProtocol.capabilitiesAcceptVersions.split(separator: ",").contains(Substring(value)) }
    static func integer(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
              n.compare(NSNumber(value: Int64.min)) != .orderedAscending,
              n.compare(NSNumber(value: Int64.max)) != .orderedDescending else { return nil }
        return n.int64Value
    }
    static func cursorMatches(_ object: Any?, _ cursor: PushCursor?) -> Bool {
        guard let cursor else { return object == nil || object is NSNull }
        guard cursor.rowId > 0, digest(cursor.naturalKeyFingerprint), let value = object as? [String: Any] else { return false }
        return integer(value["rowId"]) == cursor.rowId && value["keySha256"] as? String == cursor.naturalKeyFingerprint
    }
    static func day(_ value: String) -> Date? {
        guard value.utf8.count == 10 else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard let date = f.date(from: value), f.string(from: date) == value else { return nil }; return date
    }
    static func validWindow(_ w: PushWindow) -> Bool {
        day(w.fromDay) != nil && day(w.toDay) != nil && w.fromDay <= w.toDay && w.startTsInclusive < w.endTsExclusive
    }
    static func sameWindow(_ a: PushWindow, _ b: PushWindow) -> Bool {
        a.fromDay == b.fromDay && a.toDay == b.toDay && a.startTsInclusive == b.startTsInclusive && a.endTsExclusive == b.endTsExclusive
    }
}
