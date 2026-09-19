import Compression
import Foundation
import WhoopProtocol

/// One push-ready second of 100 Hz IMU: 600 axis-major i16 columns serialized little-endian.
struct ImuPushRecord: Sendable {
    let ts: Int64
    let columns: Data
}

/// The slice of the IMU store the cloud-push object lane reads. A protocol so push tests can
/// inject an in-memory source instead of the filesystem store.
protocol ImuSessionPushSource: Sendable {
    /// Distinct device ids with at least one registered session window.
    func pushDeviceIds() -> Set<String>
    /// Up to `limit` one-second records with ts > `afterTs`, strictly ascending by ts. Records
    /// with a malformed column count are skipped: a gap stays legible as absence on the receiver.
    func pushRecords(deviceId: String, afterTs: Int64, limit: Int) -> [ImuPushRecord]
}

/// Canonical decoded 100 Hz IMU storage: UTC half-hour files with appendable 30-second zlib blocks.
/// Thread-safe via an internal serial queue (T2-1: off the main actor; safe from `BackfillActor`).
final class ImuSessionFileStore: @unchecked Sendable {
    private let isolation = DispatchQueue(label: "com.noop.imu-session-file-store")
    struct Stats { let bytes: Int64; let coveredSeconds: Int; let firstTs: Int64? }
    struct ExportSegment { let name: String; let data: Data; let startTs, endTs: Int; let sampleCount: Int }
    /// Read-only projection of one registered capture window, for aggregating readers (the
    /// continuous recorder's coverage/export) that span more than one window.
    struct WindowInfo { let id, deviceId: String; let from: Int64; let to: Int64? }
    /// One on-disk segment's identity + size, for the continuous recorder's retention eviction.
    struct SegmentInfo { let id: String; let bucket: Int64; let bytes: Int64 }
    private struct Window: Codable { let id, deviceId: String; let from: Int64; var to: Int64? }
    private struct Record { let ts, receivedAtMs: Int64; let columns: [Int16] }
    private struct DecodedFile {
        let records: [Record]
        let validEnd: Int
        let complete: Bool
    }
    static let shared = ImuSessionFileStore()
    /// The continuous recorder's store (Developer Options → Record 100 Hz IMU locally). A SEPARATE
    /// directory + window registry from `shared` on purpose: the rawImuSession cloud-push lane reads
    /// `shared` only, so this mode's 100 Hz data stays local unless the user explicitly exports it.
    static let continuous = ImuSessionFileStore(directoryComponent: "OpenWhoop/RawImuLive",
                                                defaultsKey: "imu-live-windows-v2")
    static let sampleRate = 100, axes = 6, blockSeconds = 30
    static let segmentSeconds: Int64 = 30 * 60
    /// Per-session conflict-evidence file (FRWHOOP issue #1): a sorted JSON array of strap timestamps
    /// whose re-delivered payload DISAGREED with the first durable record. Same name + format on
    /// Android. Lives inside the session directory, so it is deleted with the session.
    static let conflictsFileName = "imu-conflicts.json"
    private static let payloadBytes = sampleRate * axes * 2
    private static let magic = Data("NOOPIMU2".utf8)
    private let defaults: UserDefaults
    private let key: String
    private let directory: URL
    /// Segment path → (strap ts → digest of its stored columns). The digest distinguishes an exact
    /// re-delivery (discard silently) from a conflicting payload (keep first, record evidence).
    private var seen: [String: [Int64: UInt64]] = [:]
    private var pending: [String: [Record]] = [:]
    /// Session id → conflicted strap timestamps (mirror of `imu-conflicts.json`; loaded lazily).
    private var conflicts: [String: Set<Int64>] = [:]

    /// Test-only: when true, appended-block verification always fails (exercises rollback).
    var testFailAppendVerification = false

    /// `directory` overrides the whole directory (tests); `directoryComponent` + `defaultsKey` pick
    /// the namespace (bounded sessions vs the continuous recorder). Not private so tests can build
    /// isolated instances; production code uses `shared` / `continuous`.
    init(directory override: URL? = nil,
         directoryComponent: String = "OpenWhoop/RawImuSessions",
         defaultsKey: String = "imu-session-windows-v1",
         defaults: UserDefaults = .standard) {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        directory = override ?? base.appendingPathComponent(directoryComponent, isDirectory: true)
        key = defaultsKey
        self.defaults = defaults
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Platform-neutral FNV-1a over the little-endian column payload. Never persisted across the
    /// .noopbak boundary, but it IS compared against digests computed on the other platform's twin
    /// in parity tests, so it must be a stable algorithm — Swift `hashValue` is randomized per run
    /// and banned here. Twin of Kotlin `ImuSessionFileStore.columnsDigest`.
    static func columnsDigest(_ columns: [Int16]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for value in columns {
            hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: value))) &* 0x100000001b3
            hash = (hash ^ UInt64(UInt8(truncatingIfNeeded: value >> 8))) &* 0x100000001b3
        }
        return hash
    }

    func start(id: String, deviceId: String, fromMs: Int64) {
        isolation.sync {
            var value = windows().filter { $0.id != id }
            value.append(Window(id: id, deviceId: deviceId, from: fromMs / 1_000, to: nil)); save(value)
            try? FileManager.default.createDirectory(at: sessionDirectory(id), withIntermediateDirectories: true)
        }
    }
    @discardableResult
    func complete(id: String, toMs: Int64) -> Bool {
        // A session must not be published complete while its final block exists only in memory. Keep
        // the window open and let the BLE/session owner retain cleanup debt when any flush fails.
        guard flushSession(id) else { return false }
        var value = windows()
        guard let index = value.firstIndex(where: { $0.id == id }) else { return false }
        value[index].to = toMs / 1_000
        save(value)
        return true
    }
    func register(id: String, deviceId: String, fromMs: Int64, toMs: Int64) {
        var value = windows().filter { $0.id != id }
        value.append(Window(id: id, deviceId: deviceId, from: fromMs / 1_000, to: toMs / 1_000)); save(value)
        try? FileManager.default.createDirectory(at: sessionDirectory(id), withIntermediateDirectories: true)
    }
    func remove(id: String) {
        pending.keys.filter { $0.hasPrefix("\(id)/") }.forEach { pending[$0] = nil }
        seen.keys.filter { $0.hasPrefix(sessionDirectory(id).path) }.forEach { seen[$0] = nil }
        conflicts[id] = nil
        save(windows().filter { $0.id != id })
    }
    func prepareForRead(_ id: String) { _ = flushSession(id) }

    func deleteFiles(_ id: String, removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Bool {
        guard flushSession(id) else { return false }
        let dir = sessionDirectory(id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return true }
        do { try removeItem(dir); return true } catch { return false }
    }

    func deleteDevice(_ deviceId: String) -> Bool {
        let owned = windows().filter { $0.deviceId == deviceId }.map(\.id)
        guard owned.allSatisfy({ deleteFiles($0) }) else { return false }
        owned.forEach { remove(id: $0) }; return true
    }

    /// True when any routing window exists for the device — lets the raw-archive repair scan
    /// short-circuit before touching the database (FRWHOOP issue #1).
    func hasWindows(deviceId: String) -> Bool { windows().contains { $0.deviceId == deviceId } }

    @discardableResult
    func append(deviceId: String, frame: [UInt8], receivedAtMs: Int64) -> Int {
        guard let decoded = Whoop5RawImu.decodeColumns(frame) else { return 0 }
        return append(deviceId: deviceId, ts: Int64(decoded.baseTs), columns: decoded.columns,
                      receivedAtMs: receivedAtMs)
    }

    @discardableResult
    func append(deviceId: String, ts: Int64, columns: [Int16], receivedAtMs: Int64) -> Int {
        appendRouting(deviceId: deviceId, sourceTs: ts, columns: columns, receivedAtMs: receivedAtMs).count
    }

    /// Backfiller commit seam (FRWHOOP issue #1): append historical IMU buffers to every matching
    /// session window and flush the touched sessions. True iff every record that matched a window is
    /// durably on disk — NO matching window is a success (nothing was owed), so an ordinary history
    /// sync never stalls on IMU. A false return makes the caller hold the trim ack (#57 pattern), so
    /// the strap re-sends the chunk next session instead of trimming past un-persisted session data.
    func persistHistoricalImu(deviceId: String, records: [(baseTs: Int, columns: [Int16])],
                              receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) -> Bool {
        isolation.sync {
            var touched: Set<String> = []
            for record in records {
                touched.formUnion(appendRouting(deviceId: deviceId, sourceTs: Int64(record.baseTs),
                                                columns: record.columns, receivedAtMs: receivedAtMs))
            }
            let toFlush = touched.union(pendingSessionIds(deviceId: deviceId))
            guard !toFlush.isEmpty else { return true }
            var ok = true
            for id in toFlush where !flushSession(id) { ok = false }
            return ok
        }
    }

    func persistHistoricalImu(deviceId: String, frames: [[UInt8]],
                              receivedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) -> Bool {
        isolation.sync {
            var records: [(baseTs: Int, columns: [Int16])] = []
            records.reserveCapacity(frames.count)
            for frame in frames {
                guard let decoded = Whoop5RawImu.decodeColumns(frame) else { continue }
                records.append((decoded.baseTs, decoded.columns))
            }
            var touched: Set<String> = []
            for record in records {
                touched.formUnion(appendRouting(deviceId: deviceId, sourceTs: Int64(record.baseTs),
                                                columns: record.columns, receivedAtMs: receivedAtMs))
            }
            let toFlush = touched.union(pendingSessionIds(deviceId: deviceId))
            guard !toFlush.isEmpty else { return true }
            var ok = true
            for id in toFlush where !flushSession(id) { ok = false }
            return ok
        }
    }

    /// Route one decoded 5/MG IMU buffer into every matching session window; returns the ids of sessions
    /// that QUEUED a new record. Duplicate policy (FRWHOOP issue #1): an identical payload at an
    /// already-stored strap second is discarded; a DIFFERENT payload keeps the first durable value
    /// and the second is recorded as conflict evidence — never silently merged or overwritten.
    /// Open live windows match by receipt time so the first complete one-second buffer after START
    /// is kept even when its source ts slightly predates the session wall clock.
    private func appendRouting(deviceId: String, sourceTs: Int64, columns: [Int16],
                               receivedAtMs: Int64) -> Set<String> {
        let receivedTs = receivedAtMs / 1_000
        var queued: Set<String> = []
        for window in windows() where window.deviceId == deviceId {
            let belongsToWindow: Bool
            if let to = window.to {
                belongsToWindow = sourceTs >= window.from && sourceTs <= to
            } else {
                belongsToWindow = receivedTs >= window.from
            }
            guard belongsToWindow else { continue }
            let bucket = Self.bucketStart(sourceTs), url = segmentFile(window.id, bucket)
            var timestamps = seen[url.path] ?? scan(url)
            let digest = Self.columnsDigest(columns)
            if let existing = timestamps[sourceTs] {
                seen[url.path] = timestamps
                if existing != digest { markConflict(window.id, sourceTs) }
                continue
            }
            timestamps[sourceTs] = digest
            seen[url.path] = timestamps
            let pendingKey = "\(window.id)/\(bucket)"
            pending[pendingKey, default: []].append(Record(ts: sourceTs, receivedAtMs: receivedAtMs, columns: columns))
            if pending[pendingKey]!.count >= Self.blockSeconds { flushKey(pendingKey) }
            queued.insert(window.id)
        }
        return queued
    }

    private func pendingSessionIds(deviceId: String) -> Set<String> {
        let deviceSessions = Set(windows().filter { $0.deviceId == deviceId }.map(\.id))
        return Set(pending.keys.map { String($0.split(separator: "/")[0]) }).intersection(deviceSessions)
    }

    // MARK: - Conflict evidence (FRWHOOP issue #1)

    /// Sorted strap timestamps inside the session whose re-delivered payload disagreed with the
    /// first durable record. Read by the export's coverage report.
    func conflictTimestamps(_ id: String) -> [Int64] {
        (conflicts[id] ?? loadConflicts(id)).sorted()
    }

    private func markConflict(_ id: String, _ ts: Int64) {
        var set = conflicts[id] ?? loadConflicts(id)
        guard set.insert(ts).inserted else { conflicts[id] = set; return }
        conflicts[id] = set
        try? FileManager.default.createDirectory(at: sessionDirectory(id), withIntermediateDirectories: true)
        try? JSONEncoder().encode(set.sorted()).write(to: conflictsFile(id), options: .atomic)
    }

    private func loadConflicts(_ id: String) -> Set<Int64> {
        guard let data = try? Data(contentsOf: conflictsFile(id)),
              let list = try? JSONDecoder().decode([Int64].self, from: data) else { return [] }
        let set = Set(list)
        conflicts[id] = set
        return set
    }

    private func conflictsFile(_ id: String) -> URL {
        sessionDirectory(id).appendingPathComponent(Self.conflictsFileName)
    }

    func stats(_ id: String, from: Int, to: Int) -> Stats {
        // Coverage needs timestamps, not decoded 6-axis payloads: the per-file `seen` index (plus
        // the still-pending records) answers without inflating every block on each UI refresh.
        var covered = Set<Int64>()
        for file in segmentFiles(id) {
            let timestamps = seen[file.path] ?? scan(file)
            seen[file.path] = timestamps
            covered.formUnion(timestamps.keys.filter { $0 >= Int64(from) && $0 <= Int64(to) })
        }
        for (pendingKey, records) in pending where pendingKey.hasPrefix("\(id)/") {
            for record in records where record.ts >= Int64(from) && record.ts <= Int64(to) {
                covered.insert(record.ts)
            }
        }
        let disk = segmentFiles(id).reduce(Int64(0)) { value, url in
            value + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let queued = pending.filter { $0.key.hasPrefix("\(id)/") }.values.flatMap { $0 }
            .reduce(Int64(0)) { $0 + Int64($1.columns.count * 2 + 20) }
        return Stats(bytes: disk + queued, coveredSeconds: covered.count, firstTs: covered.min())
    }

    /// Every registered window (routing metadata only), for readers that aggregate across windows.
    func registeredWindows() -> [WindowInfo] {
        windows().map { WindowInfo(id: $0.id, deviceId: $0.deviceId, from: $0.from, to: $0.to) }
    }

    /// Coalesced inclusive [start, end] second ranges inside [from, to] that have NO stored sample,
    /// computed one segment at a time WITHOUT retaining the seen-sets (a continuous recorder window
    /// can span weeks; pinning every timestamp set for a UI refresh would not be acceptable).
    /// Pending (not yet flushed) records count as covered. Empty result = fully covered.
    func missingRanges(_ id: String, from: Int64, to: Int64) -> [(Int64, Int64)] {
        guard from <= to else { return [] }
        var missing: [(Int64, Int64)] = []
        var bucket = Self.bucketStart(from)
        while bucket <= to {
            let lo = max(bucket, from), hi = min(bucket + Self.segmentSeconds - 1, to)
            var present = Set<Int64>()
            let url = segmentFile(id, bucket)
            if FileManager.default.fileExists(atPath: url.path) {
                present = Set((seen[url.path] ?? scan(url)).keys)
            }
            for record in pending["\(id)/\(bucket)"] ?? [] { present.insert(record.ts) }
            var ts = lo
            while ts <= hi {
                if present.contains(ts) { ts += 1; continue }
                var end = ts
                while end + 1 <= hi && !present.contains(end + 1) { end += 1 }
                if let last = missing.last, last.1 == ts - 1 {
                    missing[missing.count - 1] = (last.0, end)
                } else {
                    missing.append((ts, end))
                }
                ts = end + 1
            }
            bucket += Self.segmentSeconds
        }
        return missing
    }

    /// Every on-disk segment across every window in this store, oldest bucket first, with file sizes.
    /// The continuous recorder's retention policy evicts from this list.
    func segmentInventory() -> [SegmentInfo] {
        windows().flatMap { window in
            segmentFiles(window.id).compactMap { url in
                guard let bucket = segmentBucket(url) else { return nil }
                let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                return SegmentInfo(id: window.id, bucket: bucket, bytes: bytes)
            }
        }.sorted { $0.bucket < $1.bucket }
    }

    /// Total on-disk + queued bytes across every window in this store.
    func totalBytes() -> Int64 {
        let disk = segmentInventory().reduce(Int64(0)) { $0 + $1.bytes }
        let queued = pending.values.flatMap { $0 }
            .reduce(Int64(0)) { $0 + Int64($1.columns.count * 2 + 20) }
        return disk + queued
    }

    /// Evict ONE segment file (retention). Clears the timestamp-index cache for it so a later
    /// coverage read cannot report the evicted seconds. Callers must record their own eviction
    /// floor and refuse late frames at/below it, or an evicted second would silently regrow.
    @discardableResult
    func deleteSegment(id: String, bucket: Int64,
                       removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Bool {
        let url = segmentFile(id, bucket)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try removeItem(url)
            seen[url.path] = nil
            pending["\(id)/\(bucket)"] = nil
            return true
        } catch { return false }
    }

    func exportSegments(_ id: String, from: Int, to: Int) -> [ExportSegment] {
        guard flushSession(id) else { return [] }
        let records = Dictionary(grouping: readRecords(id, from: from, to: to, includePending: false), by: \.ts)
            .compactMap { $0.value.first }.sorted { $0.ts < $1.ts }
        return Dictionary(grouping: records) { Self.bucketStart($0.ts) }.sorted { $0.key < $1.key }.compactMap { element in
            let (bucket, rows) = element
            guard let first = rows.first, let last = rows.last,
                  let encoded = encode(bucket: bucket, records: rows) else { return nil }
            return ExportSegment(name: "imu-\(Self.utcName(bucket)).imus", data: encoded,
                startTs: Int(first.ts), endTs: Int(last.ts), sampleCount: rows.count * Self.sampleRate)
        }
    }

    private func readRecords(_ id: String, from: Int, to: Int, includePending: Bool) -> [Record] {
        var rows = segmentFiles(id).flatMap { decode((try? Data(contentsOf: $0)) ?? Data()) }
            .filter { $0.ts >= from && $0.ts <= to }
        if includePending { rows += pending.filter { $0.key.hasPrefix("\(id)/") }.values.flatMap { $0 }
            .filter { $0.ts >= from && $0.ts <= to } }
        return rows
    }

    private func encode(bucket: Int64, records: [Record]) -> Data? {
        var result = header(bucket)
        for start in stride(from: 0, to: records.count, by: Self.blockSeconds) {
            guard let encoded = block(Array(records[start..<min(start + Self.blockSeconds, records.count)])) else {
                return nil
            }
            result.append(encoded)
        }
        return result
    }
    private func decodeFile(_ data: Data) -> DecodedFile {
        guard data.count >= 24, data.prefix(8) == Self.magic else {
            return DecodedFile(records: [], validEnd: 0, complete: false)
        }
        let bytes = [UInt8](data); var offset = 8
        _ = Int64(bigEndianBytes: bytes, at: offset); offset += 8
        guard int32(bytes, offset) == Self.sampleRate, int32(bytes, offset + 4) == Self.axes else {
            return DecodedFile(records: [], validEnd: 0, complete: false)
        }
        offset += 8; var result: [Record] = []
        var validEnd = offset
        while offset < bytes.count {
            let blockStart = offset
            guard offset + 12 <= bytes.count else {
                return DecodedFile(records: result, validEnd: validEnd, complete: false)
            }
            let count = int32(bytes, offset), rawSize = int32(bytes, offset + 4), compressedSize = int32(bytes, offset + 8)
            offset += 12
            let expectedRawSize = count * (20 + Self.payloadBytes)
            guard count > 0, count <= Self.blockSeconds, rawSize == expectedRawSize, compressedSize > 0,
                  offset + compressedSize <= bytes.count,
                  let raw = inflate(Data(bytes[offset..<offset + compressedSize]), size: rawSize) else {
                return DecodedFile(records: result, validEnd: blockStart, complete: false)
            }
            let nextOffset = offset + compressedSize
            let rawBytes = [UInt8](raw); var rawOffset = 0
            var blockRecords: [Record] = []
            blockRecords.reserveCapacity(count)
            for _ in 0..<count {
                guard rawOffset + 20 + Self.payloadBytes <= rawBytes.count else {
                    return DecodedFile(records: result, validEnd: blockStart, complete: false)
                }
                let ts = Int64(bigEndianBytes: rawBytes, at: rawOffset)
                let received = Int64(bigEndianBytes: rawBytes, at: rawOffset + 8)
                let length = int32(rawBytes, rawOffset + 16); rawOffset += 20
                guard length == Self.payloadBytes, rawOffset + length <= rawBytes.count else {
                    return DecodedFile(records: result, validEnd: blockStart, complete: false)
                }
                var columns: [Int16] = []; columns.reserveCapacity(Self.sampleRate * Self.axes)
                for index in stride(from: rawOffset, to: rawOffset + length, by: 2) {
                    columns.append(Int16(bitPattern: UInt16(rawBytes[index]) | UInt16(rawBytes[index + 1]) << 8))
                }
                rawOffset += length
                blockRecords.append(Record(ts: ts, receivedAtMs: received, columns: columns))
            }
            guard rawOffset == rawBytes.count else {
                return DecodedFile(records: result, validEnd: blockStart, complete: false)
            }
            result.append(contentsOf: blockRecords)
            offset = nextOffset
            validEnd = offset
        }
        return DecodedFile(records: result, validEnd: validEnd, complete: true)
    }

    private func decode(_ data: Data) -> [Record] {
        let decoded = decodeFile(data)
        return decoded.complete ? decoded.records : []
    }

    /// Flush every pending block for the session. True iff nothing remains pending afterwards —
    /// callers on a durability-critical path (the Backfiller's flush-before-ack seam) must check it.
    @discardableResult
    private func flushSession(_ id: String) -> Bool {
        let keys = pending.keys.filter { $0.hasPrefix("\(id)/") }
        var succeeded = true
        for key in keys where !flushKey(key) { succeeded = false }
        return succeeded && !pending.keys.contains { $0.hasPrefix("\(id)/") }
    }

    @discardableResult
    private func flushKey(_ key: String) -> Bool {
        guard let tail = key.split(separator: "/").last,
              let bucket = Int64(String(tail)) else { return false }
        let id = String(key.split(separator: "/")[0]), url = segmentFile(id, bucket)
        while let records = pending[key], !records.isEmpty {
            // A transient failure leaves the complete batch pending. Later appends may grow that queue
            // beyond blockSeconds, but the on-disk decoder deliberately rejects blocks >30. Drain only
            // durable prefixes so one failed 30-row write cannot make every future retry unencodable.
            let batch = Array(records.prefix(Self.blockSeconds))
            guard let encoded = block(batch) else { return false }
            do {
                try FileManager.default.createDirectory(at: sessionDirectory(id), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try header(bucket).write(to: url, options: .atomic)
                }
                let handle = try FileHandle(forWritingTo: url)
                let originalOffset = try handle.seekToEnd()
                do {
                    try handle.write(contentsOf: encoded)
                    try handle.synchronize()
                    try handle.close()
                    guard verifyAppendedBlock(in: url, at: originalOffset, expected: encoded) else {
                        rollbackSegment(url, to: originalOffset)
                        return false
                    }
                    if records.count == batch.count {
                        pending.removeValue(forKey: key)
                    } else {
                        pending[key] = Array(records.dropFirst(batch.count))
                    }
                } catch {
                    try? handle.truncate(atOffset: originalOffset)
                    try? handle.synchronize()
                    try? handle.close()
                    return false
                }
            } catch {
                // Leave this batch and every later record pending. A later flush retries without
                // converting an encode/open/write failure into a successful empty block.
                return false
            }
        }
        return true
    }

    /// Verifies ONLY the block just appended at `offset`. Whole-file revalidation on every flush was
    /// redundant: `scan` fully decodes every complete block the first time a segment is touched per
    /// launch (building the timestamp index), and externally-corrupted mid-session files are detected
    /// at that next launch's `scan`, not at flush time. The ack-critical contract is that appended
    /// bytes are verified on disk before the Backfiller's ack.
    private func verifyAppendedBlock(in url: URL, at offset: UInt64, expected: Data) -> Bool {
        if testFailAppendVerification { return false }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let length = expected.count
        guard length > 0 else { return false }
        try? handle.seek(toOffset: offset)
        guard let read = try? handle.read(upToCount: length), read.count == length else { return false }
        guard read == expected else { return false }
        return decodeBlock(read) != nil
    }

    /// Decode one on-disk block's payload (the 12-byte header + compressed body written by `block`).
    private func decodeBlock(_ data: Data) -> [Record]? {
        let bytes = [UInt8](data)
        guard data.count >= 12 else { return nil }
        let count = int32(bytes, 0), rawSize = int32(bytes, 4), compressedSize = int32(bytes, 8)
        guard count > 0, count <= Self.blockSeconds,
              compressedSize > 0, 12 + compressedSize == data.count else { return nil }
        let expectedRawSize = count * (20 + Self.payloadBytes)
        guard rawSize == expectedRawSize,
              let raw = inflate(Data(bytes[12..<(12 + compressedSize)]), size: rawSize) else { return nil }
        let rawBytes = [UInt8](raw)
        var rawOffset = 0
        var blockRecords: [Record] = []
        blockRecords.reserveCapacity(count)
        for _ in 0..<count {
            guard rawOffset + 20 + Self.payloadBytes <= rawBytes.count else { return nil }
            let ts = Int64(bigEndianBytes: rawBytes, at: rawOffset)
            let received = Int64(bigEndianBytes: rawBytes, at: rawOffset + 8)
            let length = int32(rawBytes, rawOffset + 16)
            rawOffset += 20
            guard length == Self.payloadBytes, rawOffset + length <= rawBytes.count else { return nil }
            var columns: [Int16] = []
            columns.reserveCapacity(Self.sampleRate * Self.axes)
            for index in stride(from: rawOffset, to: rawOffset + length, by: 2) {
                columns.append(Int16(bitPattern: UInt16(rawBytes[index]) | UInt16(rawBytes[index + 1]) << 8))
            }
            rawOffset += length
            blockRecords.append(Record(ts: ts, receivedAtMs: received, columns: columns))
        }
        guard rawOffset == rawBytes.count else { return nil }
        return blockRecords
    }

    private func rollbackSegment(_ url: URL, to offset: UInt64) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.truncate(atOffset: offset)
        try? handle.synchronize()
    }
    private func header(_ bucket: Int64) -> Data {
        var data = Self.magic; data.appendBigEndian(bucket); data.appendBigEndian(Int32(Self.sampleRate)); data.appendBigEndian(Int32(Self.axes)); return data
    }
    private func block(_ records: [Record]) -> Data? {
        guard !records.isEmpty, records.count <= Self.blockSeconds else { return nil }
        var raw = Data()
        for record in records {
            raw.appendBigEndian(record.ts); raw.appendBigEndian(record.receivedAtMs); raw.appendBigEndian(Int32(Self.payloadBytes))
            for value in record.columns { raw.append(UInt8(truncatingIfNeeded: value)); raw.append(UInt8(truncatingIfNeeded: value >> 8)) }
        }
        guard let compressed = deflate(raw) else { return nil }
        var data = Data(); data.appendBigEndian(Int32(records.count)); data.appendBigEndian(Int32(raw.count))
        data.appendBigEndian(Int32(compressed.count)); data.append(compressed); return data
    }

    private func windows() -> [Window] { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Window].self, from: $0) } ?? [] }
    private func save(_ value: [Window]) { defaults.set(try? JSONEncoder().encode(value), forKey: key) }
    private func sessionDirectory(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }
    private func segmentFile(_ id: String, _ bucket: Int64) -> URL { sessionDirectory(id).appendingPathComponent("imu-\(Self.utcName(bucket)).imus") }
    private func segmentFiles(_ id: String) -> [URL] { ((try? FileManager.default.contentsOfDirectory(at: sessionDirectory(id), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "imus" }.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    private func scan(_ url: URL) -> [Int64: UInt64] {
        // Fully decodes every complete block on first touch per launch — sufficient validation for
        // pre-existing segment bytes; appended blocks are verified separately in flushKey.
        var map: [Int64: UInt64] = [:]
        for record in decode((try? Data(contentsOf: url)) ?? Data()) {
            map[record.ts] = Self.columnsDigest(record.columns)
        }
        return map
    }
    private static func bucketStart(_ ts: Int64) -> Int64 { ts >= 0 ? ts / segmentSeconds * segmentSeconds : ((ts - segmentSeconds + 1) / segmentSeconds) * segmentSeconds }
    private static func utcName(_ ts: Int64) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }
    private func int32(_ bytes: [UInt8], _ offset: Int) -> Int { Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]) }
    private func deflate(_ input: Data) -> Data? { let capacity = input.count + 128; var output = Data(count: capacity); let written = output.withUnsafeMutableBytes { dst in input.withUnsafeBytes { src in compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity, src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB) } }; guard written > 0 else { return nil }; output.count = written; return output }
    private func inflate(_ input: Data, size: Int) -> Data? { var output = Data(count: size); let written = output.withUnsafeMutableBytes { dst in input.withUnsafeBytes { src in compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size, src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB) } }; return written == size ? output : nil }
}

private extension Int64 { init(bigEndianBytes bytes: [UInt8], at offset: Int) { self = bytes[offset..<(offset + 8)].reduce(0) { ($0 << 8) | Int64($1) } } }
private extension Data { mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) { var value = value.bigEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } } }

// MARK: - Push adapter (rawImuSession object lane)

extension ImuSessionFileStore: ImuSessionPushSource {
    func pushDeviceIds() -> Set<String> {
        Set(windows().map(\.deviceId).filter { !$0.isEmpty })
    }

    func pushRecords(deviceId: String, afterTs: Int64, limit: Int) -> [ImuPushRecord] {
        let ids = windows().filter { $0.deviceId == deviceId }.map(\.id)
        guard !ids.isEmpty, limit > 0 else { return [] }
        // Segments ascend in bucket order and every record in a segment has ts >= its bucket, so
        // once `limit` records are collected and the next segment starts beyond the current
        // limit-th ts, no later segment can displace it — the read stays bounded no matter how
        // much history follows the cursor.
        var byTs: [Int64: Data] = [:]
        for id in ids {
            // Fail closed for the whole device. Advancing the uploader cursor past a torn earlier segment
            // would make that evidence permanently ineligible if the pending block is repaired later.
            guard flushSession(id) else { return [] }
            for file in segmentFiles(id) {
                guard let bucket = segmentBucket(file) else { return [] }
                guard bucket + Self.segmentSeconds > afterTs else { continue }
                if byTs.count >= limit {
                    let cutoff = byTs.keys.sorted()[limit - 1]
                    if bucket > cutoff { break }
                }
                guard let bytes = try? Data(contentsOf: file) else { return [] }
                let decoded = decodeFile(bytes)
                guard decoded.complete else { return [] }
                for record in decoded.records where record.ts > afterTs {
                    guard record.columns.count == Self.sampleRate * Self.axes, byTs[record.ts] == nil else { continue }
                    var data = Data(capacity: Self.payloadBytes)
                    for value in record.columns {
                        data.append(UInt8(truncatingIfNeeded: value))
                        data.append(UInt8(truncatingIfNeeded: value >> 8))
                    }
                    byTs[record.ts] = data
                }
            }
        }
        return byTs.sorted { $0.key < $1.key }.prefix(limit).map { ImuPushRecord(ts: $0.key, columns: $0.value) }
    }

    /// Reads just the 24-byte segment header for the bucket timestamp, so push paging can skip
    /// whole files without decoding them.
    private func segmentBucket(_ url: URL) -> Int64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 24),
              data.count >= 24,
              data.prefix(8) == Self.magic else { return nil }
        return Int64(bigEndianBytes: [UInt8](data), at: 8)
    }
}
