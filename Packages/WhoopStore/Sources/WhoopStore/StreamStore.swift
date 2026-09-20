import Foundation
import GRDB
import WhoopProtocol

/// Result of the Backfiller's atomic insert-and-mark call: the per-stream actual insert counts
/// (rows that were NOT already present) plus whether durable post-offload jobs were written for
/// this chunk. `markedJobs` is decided inside the same transaction from the SAME counts, so the
/// job rows can never disagree with what actually landed.
public struct BackfillInsertOutcome: Sendable {
    public var counts: (hr: Int, rr: Int, events: Int, battery: Int,
                        spo2: Int, skinTemp: Int, resp: Int, gravity: Int)
    public var markedJobs: Bool
    /// Newly persisted sensor observations. Events and battery samples do not establish
    /// historical-data progress; RR provenance is deliberately not counted separately because
    /// it describes an RR observation already counted by `counts.rr`.
    public var insertedHistoricalSensorRows: Int

    public init(counts: (hr: Int, rr: Int, events: Int, battery: Int,
                         spo2: Int, skinTemp: Int, resp: Int, gravity: Int),
                markedJobs: Bool, insertedHistoricalSensorRows: Int? = nil) {
        self.counts = counts
        self.markedJobs = markedJobs
        self.insertedHistoricalSensorRows = insertedHistoricalSensorRows
            ?? (counts.hr + counts.rr + counts.spo2 + counts.skinTemp + counts.resp + counts.gravity)
    }
}

private struct RRBatchSecond: Hashable {
    let ts: Int
    let transport: Int
}

extension WhoopStore {
    /// Original standard-HR notifications. Host receipt clocks do not establish beat-time coverage.
    public func standardHrReceipts(deviceId: String, from: Int, to: Int) async throws -> [StandardHRReceipt] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM standardHRReceipt WHERE deviceId = ? AND ts >= ? AND ts < ? ORDER BY receivedUnixMs, sessionId, notificationOrdinal",
                arguments: [deviceId, from, to]).compactMap { row in
                guard let bytes = RRPacketProvenance.bytes(row["rawHex"]),
                      let receipt = StandardHRReceipt.capture(bytes, sessionId: row["sessionId"],
                        notificationOrdinal: row["notificationOrdinal"], receivedUnixMs: row["receivedUnixMs"],
                        receivedMonotonicNs: row["receivedMonotonicNs"]),
                      receipt.receiptId == row["receiptId"], receipt.ts == row["ts"],
                      receipt.schemaVersion == row["schemaVersion"], receipt.clockVersion == row["clockVersion"] else { return nil }
                return receipt
            }
        }
    }
    /// Dual-read companion: legacy RR remains unchanged and carries no inferred identity.
    public func rrPacketProvenance(deviceId: String, from: Int, to: Int) async throws -> [RRPacketProvenance] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT rawHex, ts, packetId FROM rrPacketProvenance WHERE deviceId = ? AND ts >= ? AND ts < ? ORDER BY ts, recordIndex, packetId",
                arguments: [deviceId, from, to]).compactMap { row in
                let hex: String = row["rawHex"], ts: Int = row["ts"], id: String = row["packetId"]
                guard let bytes = RRPacketProvenance.bytes(hex), let packet = RRPacketProvenance.checked(bytes, mappedTs: ts), packet.packetId == id else { return nil }
                return packet
            }
        }
    }
    /// T2-3: multi-row INSERT batch size. 100 rows × 6 columns = 600 bind parameters (SQLite default 999).
    private static let streamInsertBatchSize = 100

    /// T2-3: batched `INSERT … VALUES (…),… ON CONFLICT DO NOTHING` with per-statement `changesCount`.
    private func insertStreamBatch(_ db: Database,
                                   insertPrefix: String,
                                   placeholdersPerRow: String,
                                   conflict: String,
                                   rows: [[DatabaseValueConvertible]]) throws -> Int {
        guard !rows.isEmpty else { return 0 }
        var inserted = 0
        var offset = 0
        while offset < rows.count {
            let end = min(offset + Self.streamInsertBatchSize, rows.count)
            let chunk = rows[offset..<end]
            let values = Array(repeating: placeholdersPerRow, count: chunk.count).joined(separator: ",")
            let sql = insertPrefix + values + " " + conflict
            try db.execute(sql: sql, arguments: StatementArguments(chunk.flatMap { $0 }))
            inserted += db.changesCount
            offset = end
        }
        return inserted
    }
    /// Deterministic JSON for an event payload (sorted keys so the same payload always
    /// serializes byte-identically, important for the natural-key dedupe and parity).
    static func encodePayload(_ payload: [String: ParsedValue]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    /// Pack a decoded v26 PPG waveform's samples as little-endian i16 (2 bytes/sample) — a single
    /// compact BLOB per (deviceId, ts) row instead of 24 scalar rows (issue #156 follow-up, v27). Any
    /// sample count is handled (a truncated frame can decode fewer than 24); each value is truncated to
    /// Int16's range, matching the wire format it came from (`readI16` in the decoder never produces
    /// anything wider).
    static func packPpgSamples(_ samples: [Int]) -> Data {
        var buf = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(truncatingIfNeeded: s)
            buf.append(UInt8(truncatingIfNeeded: v))
            buf.append(UInt8(truncatingIfNeeded: v >> 8))
        }
        return buf
    }

    /// Inverse of `packPpgSamples`. A trailing odd byte (a corrupt/truncated blob) is dropped rather
    /// than thrown — a read path never crashes on a malformed row.
    static func unpackPpgSamples(_ data: Data) -> [Int] {
        let bytes = [UInt8](data)
        var out = [Int](); out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let u = UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
            out.append(Int(Int16(bitPattern: u)))
            i += 2
        }
        return out
    }

    /// #423: pack the raw-IMU i16 columns to a little-endian BLOB (same wire encoding as `packPpgSamples`,
    /// an `[Int16]` source — the 6×100 columns ax…az,gx…gz). Byte-identical to Kotlin `packImuColumns`.
    static func packImuColumns(_ cols: [Int16]) -> Data {
        var buf = Data(capacity: cols.count * 2)
        for v in cols { buf.append(UInt8(truncatingIfNeeded: v)); buf.append(UInt8(truncatingIfNeeded: v >> 8)) }
        return buf
    }

    /// Inverse of `packImuColumns`; a trailing odd byte is dropped so a malformed row never crashes a read.
    static func unpackImuColumns(_ data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        var out = [Int16](); out.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count { out.append(Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))); i += 2 }
        return out
    }

    /// Rolling retention for the v27 PPG waveform table (twin of Kotlin `PPG_WAVEFORM_RETENTION_ROWS`),
    /// added for #1911. This table was previously the only UNBOUNDED blob table, and it carries by far the
    /// largest PER-ROW cost of any decoded stream: ~120 B against ~30 B for a scalar row.
    ///
    /// It is NOT the store's fastest-growing table, and this note must not be read as saying so. v26 runs
    /// only in optical windows, roughly 28,800 rows/day by #1911's own figures, where `rrInterval` banks
    /// ~100,000/day and remains the higher-volume table by bytes. Capping this one bounds the worst row,
    /// not the bulk of #1911's ~93 MB/day.
    ///
    /// **A NEWEST-N-ROWS CAP, DELIBERATELY NOT A TIME-WINDOW DROP.** #1911 proposes "dropped after the hot
    /// window", justifying it as "diagnostic-only". That justification is wrong, and the migration note on
    /// `ppgWaveformSample` in `Database.swift` is the authority: these rows are kept precisely so a better
    /// estimator, HRV-from-PPG, or a waveform viewer can later run over the ORIGINAL samples rather than
    /// the derived bpm. Deleting by wall-clock age would empty the table for exactly the user a future
    /// estimator needs most — a sporadic wearer, whose v26 seconds are spread thin over months — and a
    /// waveform, unlike an HR series, has no aggregate that survives it. Newest-N instead bounds the bytes
    /// while ALWAYS leaving a full working set to analyse, which is the same trade `v18AuxRetentionRows`
    /// below makes for the same reason.
    ///
    /// 604,800 = 7 × 86,400, matching the aux cap's "a week of strap-seconds" semantic and #1911's own
    /// 7-day hot window. The ceiling is larger than the aux table's because the row is: ~120 B/row (a 48 B
    /// packed-i16 blob for 24 samples, plus row and primary-key-index overhead) puts it at **~70 MB per
    /// device**, against ~50 MB for aux. That is the bound worth quoting; the wall-clock
    /// span is longer than the arithmetic suggests, because v26 only runs in optical windows. At #1911's
    /// ~28,800 rows/day the cap holds about **three weeks** of typical wear, and proportionally more for a
    /// sporadic wearer, which is exactly the population an age-based cutoff would have emptied. Retuning is
    /// a one-constant change with no migration once a device `row_bytes` measurement lands, and RELAXING a
    /// cap is always cheaper than imposing one on a user with a year of history.
    public static let ppgWaveformRetentionRows = 604_800

    /// Rows to bank before sweeping `ppgWaveformSample` again, same amortisation as
    /// `v18AuxPruneEveryRows` below and the same magnitude for the same reason: the sweep walks up to
    /// `ppgWaveformRetentionRows` index entries, so running it per insert batch is the cost. The table may
    /// sit this many rows (plus the crossing batch) above the cap in exchange, roughly a MB against its
    /// ~70 MB bound.
    ///
    /// WHAT THIS BUDGET DOES NOT GUARANTEE, and the reason the cap above is stated as a size rather than a
    /// "hard ceiling": the counter is in-memory and per store instance, so a process restart resets it.
    /// The sweep is the ONLY thing enforcing retention on this table — `Collector.prune` covers the raw
    /// outbox alone, and the `*ByTs` deletes belong to `TimestampHeal`, not to retention — so a store that
    /// never banks this many rows in one process lifetime never sweeps at all. It is not a concern for the
    /// normal shape (the budget accumulates across every batch of a session, and one night's offload banks
    /// ~28,800 rows, crossing it twice over), but a store fed only short bursts between app kills can drift
    /// above the cap indefinitely. `v18AuxPruneEveryRows` below has the identical property; a sweep forced
    /// once per session would close it for both, and belongs in a change that covers both.
    public static let ppgWaveformPruneEveryRows = 10_000

    /// v31 rolling retention for the v18 aux-slot table (twin of Kotlin `V18_AUX_RETENTION_ROWS`).
    ///
    /// Raw instrumentation must be capped rather than unbounded. Nothing reads these rows yet, so a cap is far
    /// cheaper to RELAX later than to impose once users have a year of history. Unbounded, this table is
    /// the one genuinely new source of row growth in v31 (the four named channels only WIDEN rows that
    /// were already being written: ~14 bytes on a `gravitySample`/`skinTempSample`/`sleepStateSample` row
    /// that exists either way, adding no rows at all).
    ///
    /// 604,800 = 7 × 86,400, i.e. a week of strap-seconds if the strap emitted v18 every second of every
    /// day. At ~85 B/row (a ≤30 B blob plus row and primary-key-index overhead) that is a **~50 MB hard
    /// ceiling**; in practice v18 seconds are a fraction of a day, so the same cap spans considerably
    /// longer in wall-clock terms. Per device, newest-first — a multi-device store gets the cap each.
    ///
    /// This does re-introduce a bounded version of the loss this migration exists to stop: a slot older
    /// than the window is gone again. That is the deliberate trade — a census needs weeks of records, not
    /// years, and the alternative is an invisible table that can outgrow everything a user actually reads.
    public static let v18AuxRetentionRows = 604_800

    /// Rows to bank before running the retention sweep again. The sweep walks up to
    /// `v18AuxRetentionRows` index entries, so running it per insert batch was the cost; the table may sit
    /// this many rows (plus the crossing batch) above the cap in exchange, well under a MB against its
    /// ~50 MB ceiling.
    public static let v18AuxPruneEveryRows = 10_000

    /// Insert or update a device row (natural key = id).
    public func upsertDevice(id: String, mac: String?, name: String?) async throws {
        let now = Int(Date().timeIntervalSince1970)
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO device (id, mac, name, firstSeen, lastSeen)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    mac = excluded.mac,
                    name = excluded.name,
                    lastSeen = excluded.lastSeen
                """, arguments: [id, mac, name, now, now])
        }
    }

    /// Idempotent upsert of decoded streams by natural key. Returns the number of rows
    /// ACTUALLY inserted per stream (0 for rows that already existed).
    ///
    /// NOTE: the `synced` column (added by migration v5 for a since-removed server-upload feature)
    /// is intentionally NOT written here, it is unused and defaults to 0. The column is left in the
    /// schema to avoid a DROP COLUMN migration over existing data; nothing reads it.
    @discardableResult
    public func insert(_ streams: Streams, deviceId: String) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        try await insert(streams, deviceId: deviceId,
                         v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
                         v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows,
                         ppgWaveformRetentionRows: WhoopStore.ppgWaveformRetentionRows,
                         ppgWaveformPruneEveryRows: WhoopStore.ppgWaveformPruneEveryRows)
    }

    /// `insert(_:deviceId:)` with the v31 aux-table cap made explicit. Internal and a SEPARATE overload
    /// rather than a defaulted parameter on the public entry point: `StoreWriting` / `BackfillStoreWriting`
    /// require `insert(_:deviceId:)` exactly, and a Swift witness must match the requirement's parameter
    /// list — a default argument does not satisfy it. Exists so a test can prove the rolling delete with a
    /// small cap instead of writing 600k rows; every production caller goes through the wrapper above.
    ///
    /// The two v18-aux caps are required because eleven existing call sites already pass them; the two
    /// ppg-waveform caps added for #1911 are DEFAULTED so those same call sites keep compiling untouched.
    /// A default is fine on this overload (unlike the public entry point, per the note above) because
    /// nothing witnesses it against a protocol requirement.
    @discardableResult
    func insert(_ streams: Streams, deviceId: String, v18AuxRetentionRows: Int,
                v18AuxPruneEveryRows: Int,
                ppgWaveformRetentionRows: Int = WhoopStore.ppgWaveformRetentionRows,
                ppgWaveformPruneEveryRows: Int = WhoopStore.ppgWaveformPruneEveryRows) async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        try await insertAndMarkIfNeeded(
            streams,
            deviceId: deviceId,
            postOffloadJobKinds: [],
            note: nil,
            v18AuxRetentionRows: v18AuxRetentionRows,
            v18AuxPruneEveryRows: v18AuxPruneEveryRows,
            ppgWaveformRetentionRows: ppgWaveformRetentionRows,
            ppgWaveformPruneEveryRows: ppgWaveformPruneEveryRows
        ).counts
    }

    /// Backfill-only atomic variant: insert the decoded streams and, when any scoring input actually
    /// landed, upsert the durable post-offload `syncJob` rows in the SAME transaction. A throw rolls
    /// everything back, so the Backfiller holds the trim ack and an unacked chunk replayed after
    /// process death re-inserts its still-absent rows and re-records the debt. Mirrors Android's
    /// atomic `WhoopRepository.insert(... markPostBackfillDebt = true)`.
    ///
    /// `synced`-relevant columns are untouched (see `insert(_:deviceId:)`); only the `syncJob` rows are
    /// new here. `BackfillInsertOutcome.markedJobs` tells the Backfiller whether this chunk generated a
    /// fresh generation of downstream work.
    @discardableResult
    public func insertAndMarkJobsOwed(_ streams: Streams, deviceId: String,
                                      postOffloadJobKinds: [String],
                                      note: String? = nil) async throws -> BackfillInsertOutcome {
        try await insertAndMarkIfNeeded(
            streams,
            deviceId: deviceId,
            postOffloadJobKinds: postOffloadJobKinds,
            note: note,
            v18AuxRetentionRows: WhoopStore.v18AuxRetentionRows,
            v18AuxPruneEveryRows: WhoopStore.v18AuxPruneEveryRows
        )
    }

    /// The single write transaction behind both entry points. `postOffloadJobKinds` upserts one fresh
    /// token per kind on the first chunk that inserts a scoring row; a duplicate-only replay inserts
    /// zero rows and therefore neither refreshes nor removes the debt.
    ///
    /// Backfill range-skip (v45): when enabled and `postOffloadJobKinds` is non-empty, each stream's
    /// insert loop is skipped when the chunk's max ts for that stream is at/below the persisted
    /// frontier. Safety invariant: persist-before-ack means everything at/below the frontier was
    /// durably written before the trim advanced; the strap only re-sends at/below the frontier when
    /// an ack was held or lost — exactly already-persisted chunks. Live rows never consult the
    /// frontier. Accepted edge: a backfill chunk of genuinely-new rows with ts ≤ frontier (cross-chunk
    /// ts disorder or a cross-session clock-ref shift) would be skipped.
    @discardableResult
    private func insertAndMarkIfNeeded(_ streams: Streams, deviceId: String,
                                       postOffloadJobKinds: [String],
                                       note: String?,
                                       v18AuxRetentionRows: Int,
                                       v18AuxPruneEveryRows: Int,
                                       ppgWaveformRetentionRows: Int = WhoopStore.ppgWaveformRetentionRows,
                                       ppgWaveformPruneEveryRows: Int = WhoopStore.ppgWaveformPruneEveryRows
    ) async throws -> BackfillInsertOutcome {
        // Banked rows, accumulated across batches so the sweep does not run on every one.
        var v18Written = 0
        var ppgWaveformWritten = 0
        let result: (counts: (Int, Int, Int, Int, Int, Int, Int, Int), markedJobs: Bool,
                     insertedHistoricalSensorRows: Int)
            = try syncWrite { db in
            var hr = 0, rr = 0, ev = 0, bat = 0
            var spo2 = 0, skin = 0, resp = 0, grav = 0
            var stepsInserted = 0
            var sleepStateInserted = 0
            var ppgHrInserted = 0
            var rrPacketsInserted = 0
            var rrSourcesPromoted = 0
            // A high timestamp proves neither complete earlier coverage nor complete same-second
            // identities. Always attempt durable natural-key inserts before allowing the caller to ACK.
            // Keep the installed v45 table as a diagnostic watermark; never use it to suppress input.
            func recordFrontier(_ stream: String, timestamps: [Int]) throws {
                guard !postOffloadJobKinds.isEmpty, let chunkMax = timestamps.max() else { return }
                try db.execute(sql: """
                    INSERT INTO backfillFrontier (deviceId, stream, maxTs) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, stream) DO UPDATE SET maxTs = MAX(maxTs, excluded.maxTs)
                    """, arguments: [deviceId, stream, chunkMax])
            }
            // Reuse one prepared statement per table instead of recompiling the same SQL on every
            // row. This is the hottest write path (every Collector.flush + every Backfiller chunk
            // over potentially millions of historical rows). cachedStatement persists the compiled
            // statement on the connection across insert() calls too. Each loop is guarded so empty
            // streams (the common live case) compile nothing.
            if !streams.hr.isEmpty {
                let rowArgs = streams.hr.map { [$0.ts, $0.bpm] as [DatabaseValueConvertible] }
                hr += try insertStreamBatch(
                    db,
                    insertPrefix: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ",
                    placeholdersPerRow: "(?, ?, ?)",
                    conflict: "ON CONFLICT(deviceId, ts) DO NOTHING",
                    rows: rowArgs.map { [deviceId] + $0 })
                try recordFrontier("hr", timestamps: streams.hr.map(\.ts))
            }
            // Identity-based companion records bypass the legacy timestamp frontier. They are never
            // synthesized from old rrInterval rows or pruned without verified archive retention.
            if !streams.rrPackets.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO rrPacketProvenance (deviceId, packetId, ts, sensorTs, recordIndex, rawHex,
                        srcChannel, schemaVersion, decoderVersion, clockVersion, timestampPrecisionSeconds, clockOffsetSeconds, declaredCount)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, packetId) DO NOTHING
                    """)
                for p in streams.rrPackets {
                    guard let bytes = RRPacketProvenance.bytes(p.rawHex), RRPacketProvenance.checked(bytes, mappedTs: p.ts) == p else { continue }
                    try stmt.execute(arguments: [deviceId, p.packetId, p.ts, p.sensorTs, p.recordIndex, p.rawHex,
                        p.srcChannel, p.schemaVersion, p.decoderVersion, p.clockVersion, p.timestampPrecisionSeconds, p.clockOffsetSeconds, p.declaredCount])
                    rrPacketsInserted += db.changesCount
                }
            }
            if !streams.standardHrReceipts.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO standardHRReceipt (deviceId, receiptId, ts, sessionId, notificationOrdinal,
                        receivedUnixMs, receivedMonotonicNs, rawHex, schemaVersion, clockVersion)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(deviceId, receiptId) DO NOTHING
                    """)
                for p in streams.standardHrReceipts where p.isValid {
                    try stmt.execute(arguments: [deviceId, p.receiptId, p.ts, p.sessionId, p.notificationOrdinal,
                        p.receivedUnixMs, p.receivedMonotonicNs, p.rawHex, p.schemaVersion, p.clockVersion])
                }
            }
            if !streams.rr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord, srcChannel)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, rrMs, seq) DO NOTHING
                    """)
                // v24 (#163): number EQUAL (ts, rrMs) beats 0, 1, … within this batch so both survive;
                // distinct beats keep seq 0 and their own (ts, rrMs, 0) key, so a distinct beat is never
                // dropped even across batches (rrMs stays in the key). Re-syncing identical rows reproduces
                // the same (ts, rrMs, seq) → still idempotent. Nested dict = (ts, rrMs) occurrence counter.
                //
                // v30 (#823): `ord` is the beat's position among ALL beats sharing this ts in this batch —
                // its emission order. `seq` cannot express it (it keys on (ts, rrMs), so distinct beats in
                // a second are all 0). Not in the key, never changes which rows survive; it exists so reads
                // return beats in heart order rather than sorted by value, which biases RMSSD down. Same
                // batch-local caveat as seq: a second split across two live flushes restarts ord at 0 and
                // DO NOTHING keeps the first row. The historical path delivers a second atomically.
                // Twin of Kotlin assignRrSeq.
                //
                // `srcChannel` carries Oura optical channels or WHOOP 5 transport provenance. WHOOP 4
                // and legacy rows stay NULL. Like `ord` it is OUTSIDE the key: two observations of a beat can
                // yield the same (ts, rrMs), and keying on the label would store both — which is precisely
                // the double-count this fixes. A collision never inserts another beat. A newly observed
                // canonical WHOOP 5 transport can promote the existing source and order below; the read
                // filter separates sources across the full requested interval.
                let promote = try db.cachedStatement(sql: """
                    UPDATE rrInterval SET srcChannel = :source, ord = :ord,
                        rowid = (SELECT COALESCE(MAX(rowid), 0) + 1 FROM rrInterval)
                    WHERE deviceId = :device AND ts = :ts AND rrMs = :rr AND seq = :seq
                    AND ((:source = 5 AND (srcChannel IS NULL OR srcChannel IN (6, 7)))
                      OR (:source = 7 AND (srcChannel IS NULL OR srcChannel = 6)))
                    """)
                var seqByTsRr: [RRBatchSecond: [Int: Int]] = [:]
                var ordByTs: [RRBatchSecond: Int] = [:]
                for r in streams.rr {
                    // A second's native historical array is atomic. A standard packet in the same
                    // batch must not change its order or the occurrence number of an equal interval.
                    let key = RRBatchSecond(ts: r.ts,
                        transport: r.srcChannel?.isWhoop5Transport == true ? r.srcChannel!.rawValue : 0)
                    let seq = seqByTsRr[key]?[r.rrMs] ?? 0
                    seqByTsRr[key, default: [:]][r.rrMs] = seq + 1
                    let ord = ordByTs[key] ?? 0
                    ordByTs[key] = ord + 1
                    try stmt.execute(arguments: [deviceId, r.ts, r.rrMs, seq, ord,
                                                 r.srcChannel?.rawValue])
                    let inserted = db.changesCount
                    rr += inserted
                    if inserted == 0, let source = r.srcChannel,
                       source == .whoop5Historical || source == .whoop5Standard {
                        // Canonical precedence is history > standard > native/legacy. The winning
                        // observation supplies its order; values/keys and Oura labels remain intact.
                        // The natural beat key and all other columns remain intact. Advancing rowid
                        // re-exports changed provenance through append cursors; a metadata-only change
                        // must also create durable scoring debt before ACK.
                        try promote.execute(arguments: ["source": source.rawValue, "ord": ord,
                            "device": deviceId, "ts": r.ts, "rr": r.rrMs, "seq": seq])
                        rrSourcesPromoted += db.changesCount
                    }
                }
                try recordFrontier("rr", timestamps: streams.rr.map(\.ts))
            }
            if !streams.events.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO event (deviceId, ts, kind, payloadJSON) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, kind) DO NOTHING
                    """)
                for e in streams.events {
                    let json = try WhoopStore.encodePayload(e.payload)
                    try stmt.execute(arguments: [deviceId, e.ts, e.kind, json])
                    ev += db.changesCount
                }
                try recordFrontier("event", timestamps: streams.events.map(\.ts))
            }
            if !streams.battery.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO battery (deviceId, ts, soc, mv, charging) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for b in streams.battery {
                    try stmt.execute(arguments: [deviceId, b.ts, b.soc, b.mv, b.charging])
                    bat += db.changesCount
                }
                try recordFrontier("battery", timestamps: streams.battery.map(\.ts))
            }
            if !streams.spo2.isEmpty {
                spo2 += try insertStreamBatch(
                    db,
                    insertPrefix: "INSERT INTO spo2Sample (deviceId, ts, red, ir) VALUES ",
                    placeholdersPerRow: "(?, ?, ?, ?)",
                    conflict: "ON CONFLICT(deviceId, ts) DO NOTHING",
                    rows: streams.spo2.map { [deviceId, $0.ts, $0.red, $0.ir] })
                try recordFrontier("spo2", timestamps: streams.spo2.map(\.ts))
            }
            // `aux1Raw`/`aux2Raw` (v31) are the two auxiliary thermal channels riding the same v18 record
            // as the primary reading. nil (a WHOOP 4.0, or a byte that failed the decoder's thermal gate)
            // stores SQL NULL, so an absent channel stays absent.
            if !streams.skinTemp.isEmpty {
                skin += try insertStreamBatch(
                    db,
                    insertPrefix: "INSERT INTO skinTempSample (deviceId, ts, raw, aux1Raw, aux2Raw) VALUES ",
                    placeholdersPerRow: "(?, ?, ?, ?, ?)",
                    conflict: "ON CONFLICT(deviceId, ts) DO NOTHING",
                    rows: streams.skinTemp.map { [deviceId, $0.ts, $0.raw, $0.aux1Raw, $0.aux2Raw] })
                try recordFrontier("skinTemp", timestamps: streams.skinTemp.map(\.ts))
            }
            if !streams.resp.isEmpty {
                resp += try insertStreamBatch(
                    db,
                    insertPrefix: "INSERT INTO respSample (deviceId, ts, raw) VALUES ",
                    placeholdersPerRow: "(?, ?, ?)",
                    conflict: "ON CONFLICT(deviceId, ts) DO NOTHING",
                    rows: streams.resp.map { [deviceId, $0.ts, $0.raw] })
                try recordFrontier("resp", timestamps: streams.resp.map(\.ts))
            }
            // `dynAccel` (v31) is the strap's OWN gravity-removed motion magnitude for the same second —
            // stored BESIDE the vector, never in place of it, and read by nothing. nil (a WHOOP 4.0, or an
            // f32 outside the decoder's [0, 8] g gate) stores SQL NULL.
            if !streams.gravity.isEmpty {
                grav += try insertStreamBatch(
                    db,
                    insertPrefix: "INSERT INTO gravitySample (deviceId, ts, x, y, z, dynAccel) VALUES ",
                    placeholdersPerRow: "(?, ?, ?, ?, ?, ?)",
                    conflict: "ON CONFLICT(deviceId, ts) DO NOTHING",
                    rows: streams.gravity.map { [deviceId, $0.ts, $0.x, $0.y, $0.z, $0.dynAccel] })
                try recordFrontier("gravity", timestamps: streams.gravity.map(\.ts))
            }
            // WHOOP5 step counter (#78). Persist-only, the count is not surfaced in the return tuple
            // (no consumer reads it; keeping the 8-field tuple avoids touching any caller/test).
            // `activityClass` (#316, v19 column) is the @63 activity-class enum (0=still/1=walk/2=run) the
            // decoder already carries on each StepSample; it was dropped here before v19. Bound as `s.activityClass`
            //, nil (the byte was 0xFF/invalid/absent) stores SQL NULL, so an absent class stays absent.
            if !streams.steps.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO stepSample (deviceId, ts, counter, activityClass) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                var insertedStepTimestamps: [Int] = []
                for s in streams.steps {
                    try stmt.execute(arguments: [deviceId, s.ts, s.counter, s.activityClass])
                    let inserted = db.changesCount
                    stepsInserted += inserted
                    if inserted > 0 { insertedStepTimestamps.append(s.ts) }
                }
                stepDataRevision.record(deviceId: deviceId, insertedTimestamps: insertedStepTimestamps)
                try recordFrontier("steps", timestamps: streams.steps.map(\.ts))
            }
            // Band sleep_state (#175). Persist-only, same as steps — the strap's OWN @81 high-nibble state
            // (0 wake/1 still/2 asleep/3 up), decoded and streamed but dropped at storage until now. Keyed by
            // (deviceId, ts); ON CONFLICT DO NOTHING keeps the first-seen state for a second so a re-sync is
            // idempotent. The raw 0-3 code is stored verbatim — a strap that never reports it inserts nothing.
            // `rawByte` (v31) is the WHOLE @81 byte; `state` remains exactly its high nibble, so every
            // existing #175 consumer is bit-identical. nil stores SQL NULL.
            if !streams.sleepState.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO sleepStateSample (deviceId, ts, state, rawByte) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.sleepState {
                    try stmt.execute(arguments: [deviceId, s.ts, s.state, s.rawByte])
                    sleepStateInserted += db.changesCount
                }
                try recordFrontier("sleepState", timestamps: streams.sleepState.map(\.ts))
            }
            // PPG-derived HR from the v26 optical buffer (#156). Persist-only, same as steps, the count
            // is not added to the 8-field return tuple (the Backfiller call site reads that tuple by name;
            // extending it would ripple), so it is inserted without being counted. ON CONFLICT DO NOTHING
            // keeps the FIRST estimate for a second; the measured hrSample is never touched here.
            if !streams.ppgHr.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO ppgHrSample (deviceId, ts, bpm, conf) VALUES (?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.ppgHr {
                    try stmt.execute(arguments: [deviceId, s.ts, s.bpm, s.conf])
                    ppgHrInserted += db.changesCount
                }
                try recordFrontier("ppgHr", timestamps: streams.ppgHr.map(\.ts))
            }
            // RAW v26 optical PPG waveform (#156 follow-up) — the samples `ppgHr` above is derived FROM.
            // Persist-only, same as steps/sleepState/ppgHr: not added to the 8-field return tuple. ON
            // CONFLICT DO NOTHING keeps the first waveform for each wire identity. Multiple records
            // in the same second survive. Packed into one compact BLOB per row (see
            // `packPpgSamples`) rather than 24 scalar rows, so this insert is O(records), not O(samples).
            // A timestamp frontier cannot establish that all records in a second were committed.
            if !streams.ppgWaveform.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO ppgWaveformSample (deviceId, ts, samples, burstIndex, recordIndex)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, ts, recordIndex) DO NOTHING
                    """)
                for s in streams.ppgWaveform {
                    try stmt.execute(arguments: [deviceId, s.ts, WhoopStore.packPpgSamples(s.samples),
                                                 s.burstIndex, s.recordIndex ?? -1])
                    ppgWaveformWritten += db.changesCount
                }
            }
            // Every remaining v18 slot (v31), one compact blob per strap-second. Persist-only, same as
            // steps/sleepState/ppgHr/ppgWaveform: not added to the 8-field return tuple. A sample whose
            // slots are all absent packs to empty and is SKIPPED rather than banking a meaningless row —
            // which is also what keeps a WHOOP 4.0 offload from writing here at all.
            if !streams.v18Aux.isEmpty {
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO v18AuxSample (deviceId, ts, fields) VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO NOTHING
                    """)
                for s in streams.v18Aux {
                    let blob = V18AuxCodec.pack(s)
                    if blob.isEmpty { continue }
                    try stmt.execute(arguments: [deviceId, s.ts, blob])
                    // A replayed historical frame must not consume retention or progress budget.
                    v18Written += db.changesCount
                }
                try recordFrontier("v18Aux", timestamps: streams.v18Aux.map(\.ts))
            }
            // The debt decision lives on the ACTUAL insert counts (including streams the 8-field tuple
            // does not carry): a duplicate-only replay inserts zero rows and must neither eat the debt
            // nor refresh it. Every stream that appears in the scoring fingerprint is represented here.
            let scoringInserted = hr + rr + ev + spo2 + skin + resp + grav
                + stepsInserted + sleepStateInserted + ppgHrInserted + rrPacketsInserted + rrSourcesPromoted
            var markedJobs = false
            if scoringInserted > 0, !postOffloadJobKinds.isEmpty {
                let now = Int(Date().timeIntervalSince1970)
                let stmt = try db.cachedStatement(sql: """
                    INSERT INTO syncJob (kind, owedAt, token, attempts, lastNote)
                    VALUES (?, ?, ?, 0, ?)
                    ON CONFLICT(kind) DO UPDATE SET
                        owedAt = excluded.owedAt,
                        token = excluded.token,
                        attempts = 0,
                        lastNote = excluded.lastNote
                    """)
                for kind in postOffloadJobKinds {
                    try stmt.execute(arguments: [kind, now, UUID().uuidString, note])
                }
                markedJobs = true
            }
            // Preserve every independently stored sensor observation for historical progress.
            // RR provenance and canonical-source rows are derived copies of the RR observation,
            // so counting them again would falsely advance progress.
            let historicalSensorRows = hr + rr + spo2 + skin + resp + grav
                + stepsInserted + sleepStateInserted + ppgHrInserted + ppgWaveformWritten + v18Written
            return (counts: (hr, rr, ev, bat, spo2, skin, resp, grav), markedJobs: markedJobs,
                    insertedHistoricalSensorRows: historicalSensorRows)
        }

        // Rolling retention is amortised. The delete finds the Nth-newest row by rank, so it walks up to
        // `v18AuxRetentionRows` index entries. The 604,800-row cap is swept
        // once per `v18AuxPruneEveryRows` rows instead, which keeps newest-N-rows exactly (a time window
        // would not — a sporadically-worn strap's rows span far more than a week, and the census wants
        // that). Counter is per device because the delete is.
        if v18Written > 0 {
            let banked = (v18AuxRowsSincePrune[deviceId] ?? 0) + v18Written
            v18AuxRowsSincePrune[deviceId] = banked
            // BEST-EFFORT, and it has to be: the rows above are already committed, because the sweep is
            // now its own transaction rather than riding the insert's. A throw here would surface as an
            // insert failure and make Backfiller re-send a chunk it has already banked. Leaving the budget
            // unspent instead means the next batch simply retries the sweep.
            if banked >= v18AuxPruneEveryRows,
               (try? syncWrite { db in
                   try db.execute(sql: """
                       DELETE FROM v18AuxSample WHERE deviceId = ? AND ts < (
                           SELECT MIN(ts) FROM (
                               SELECT ts FROM v18AuxSample WHERE deviceId = ? ORDER BY ts DESC LIMIT ?))
                       """, arguments: [deviceId, deviceId, v18AuxRetentionRows])
               }) != nil {
                v18AuxRowsSincePrune[deviceId] = 0
            }
        }
        // #1911 rolling retention for the waveform blobs, amortised and best-effort on exactly the same
        // terms as the aux sweep above (see `ppgWaveformRetentionRows` for why this is a newest-N cap and
        // not an age-based drop). Its own counter and its own transaction: a batch routinely writes one of
        // these two tables and not the other, and a failed sweep here must not fail an insert whose rows
        // are already committed — leaving the budget unspent simply retries on the next batch.
        if ppgWaveformWritten > 0 {
            let banked = (ppgWaveformRowsSincePrune[deviceId] ?? 0) + ppgWaveformWritten
            ppgWaveformRowsSincePrune[deviceId] = banked
            if banked >= ppgWaveformPruneEveryRows,
               (try? syncWrite { db in
                   try db.execute(sql: """
                       DELETE FROM ppgWaveformSample WHERE deviceId = ? AND ts < (
                           SELECT MIN(ts) FROM (
                               SELECT ts FROM ppgWaveformSample WHERE deviceId = ? ORDER BY ts DESC LIMIT ?))
                       """, arguments: [deviceId, deviceId, ppgWaveformRetentionRows])
               }) != nil {
                ppgWaveformRowsSincePrune[deviceId] = 0
            }
        }
        return BackfillInsertOutcome(counts: result.counts, markedJobs: result.markedJobs,
                                     insertedHistoricalSensorRows: result.insertedHistoricalSensorRows)
    }

    // MARK: - Raw sensor CSV export (diagnostic)

    /// Long-format CSV column order. One stream's columns are filled per row; the rest stay blank.
    private static let rawCSVHeader =
        "unix_s,iso_utc,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter," +
        "ppg_bpm,ppg_conf,spo2_red,spo2_ir,skintemp_raw,resp_raw,band_sleep_state,event_kind,event_payload"

    /// One assembled CSV line: the 16 columns AFTER the `unix_s,iso_utc` prefix, joined with commas.
    /// `cols[0]` is the `stream` name; `cols[1...15]` are the per-stream value slots, only the ones
    /// that belong to this row's stream are non-empty.
    private struct RawCSVRow {
        let ts: Int
        var cols: [String]
        init(ts: Int) { self.ts = ts; self.cols = Array(repeating: "", count: 16) }
    }

    /// Export the decoded per-sample sensor streams NOOP already stores to ONE combined long-format CSV
    /// (header + one row per sample, all streams interleaved and sorted by ts ascending). On-device,
    /// plain text, no BLE hex, a diagnostic so power users / external devs can prototype sleep/activity/
    /// VBT algorithms on real data without a BLE stream (#308/#276/#322).
    ///
    /// `since` is a unix-seconds floor (caller passes now-24h); rows with `ts >= since` for `deviceId`
    /// are included. Writes to a temp file and returns its URL (caller hands it to the share/save flow).
    public func exportRawCSV(deviceId: String, since: TimeInterval) async throws -> URL {
        let floor = Int(since)
        let rows: [RawCSVRow] = try syncRead { db in
            var out: [RawCSVRow] = []

            // hr: stream=hr → hr_bpm (col 3).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, bpm FROM hrSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "hr"
                row.cols[1] = WhoopStore.intStr(r["bpm"])
                out.append(row)
            }
            // rr: stream=rr → rr_ms (col 4). Same-second beats need the #823 tiebreak here too, and
            // more so: bare "ORDER BY ts" left their order UNDEFINED, so a raw export could differ
            // between runs over identical data. Emission order first, then the pre-v30 fallback.
            //
            // DELIBERATELY UNFILTERED by `srcChannel`, unlike the scoring read (#1071). This is the raw
            // dump: both optical channels are real measurements, and the whole point of keeping the
            // second one is that it can be inspected against the first. A raw export that silently hid
            // half the stored rows would make the duplication that motivated v32 un-diagnosable from an
            // export — which is exactly how it WAS diagnosed.
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, rrMs FROM rrInterval WHERE deviceId = ? AND ts >= ? " +
                "ORDER BY ts, ord, rrMs, seq",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "rr"
                row.cols[2] = WhoopStore.intStr(r["rrMs"])
                out.append(row)
            }
            // gravity: stream=gravity → grav_x/y/z (cols 5–7).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, x, y, z FROM gravitySample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "gravity"
                row.cols[3] = WhoopStore.dblStr(r["x"])
                row.cols[4] = WhoopStore.dblStr(r["y"])
                row.cols[5] = WhoopStore.dblStr(r["z"])
                out.append(row)
            }
            // steps: stream=steps → step_counter (col 8).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, counter FROM stepSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "steps"
                row.cols[6] = WhoopStore.intStr(r["counter"])
                out.append(row)
            }
            // ppghr: stream=ppghr → ppg_bpm/ppg_conf (cols 9–10).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, bpm, conf FROM ppgHrSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "ppghr"
                row.cols[7] = WhoopStore.dblStr(r["bpm"])
                row.cols[8] = WhoopStore.dblStr(r["conf"])
                out.append(row)
            }
            // spo2: stream=spo2 → spo2_red/spo2_ir (cols 11–12).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, red, ir FROM spo2Sample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "spo2"
                row.cols[9] = WhoopStore.intStr(r["red"])
                row.cols[10] = WhoopStore.intStr(r["ir"])
                out.append(row)
            }
            // skintemp: stream=skintemp → skintemp_raw (col 13).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, raw FROM skinTempSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "skintemp"
                row.cols[11] = WhoopStore.intStr(r["raw"])
                out.append(row)
            }
            // resp: stream=resp → resp_raw (col 14).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, raw FROM respSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "resp"
                row.cols[12] = WhoopStore.intStr(r["raw"])
                out.append(row)
            }
            // band sleep_state (#175): stream=band_sleep_state → band_sleep_state (col 15). The strap's
            // OWN @81 high-nibble state (0 wake/1 still/2 asleep/3 up), carried verbatim.
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, state FROM sleepStateSample WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "band_sleep_state"
                row.cols[13] = WhoopStore.intStr(r["state"])
                out.append(row)
            }
            // event: stream=event → event_kind/event_payload (cols 16–17). Payload is free-form JSON,
            // so it always goes through the CSV-quote escaper (commas/quotes/newlines).
            for r in try Row.fetchAll(db, sql:
                "SELECT ts, kind, payloadJSON FROM event WHERE deviceId = ? AND ts >= ? ORDER BY ts",
                arguments: [deviceId, floor]) {
                var row = RawCSVRow(ts: r["ts"]); row.cols[0] = "event"
                row.cols[14] = WhoopStore.csvField(r["kind"] ?? "")
                row.cols[15] = WhoopStore.csvField(r["payloadJSON"] ?? "")
                out.append(row)
            }

            // Stable sort by ts ascending. `sorted` is not guaranteed stable, but ties only occur across
            // different streams at the same second, any interleaving of those is acceptable here.
            out.sort { $0.ts < $1.ts }
            return out
        }

        // Stream the rows straight to disk through a FileHandle, flushing in ~64 KB chunks, instead of
        // building the whole CSV as one in-memory String: a busy 24 h export otherwise held tens of MB
        // twice, the assembled String plus its UTF-8 Data copy that `write(to:)` makes, and could OOM
        // (#406, parity with the Android exporter's streaming fix).
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.formatOptions = [.withInternetDateTime]

        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-raw-sensors-\(stamp).csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data((WhoopStore.rawCSVHeader + "\n").utf8))
        var buf = String()
        buf.reserveCapacity(72 * 1024)
        for row in rows {
            let isoStr = iso.string(from: Date(timeIntervalSince1970: TimeInterval(row.ts)))
            buf += "\(row.ts),\(isoStr),"
            buf += row.cols.joined(separator: ",")
            buf += "\n"
            if buf.utf8.count >= 64 * 1024 {
                try handle.write(contentsOf: Data(buf.utf8))
                buf.removeAll(keepingCapacity: true)
            }
        }
        if !buf.isEmpty { try handle.write(contentsOf: Data(buf.utf8)) }
        return url
    }

    /// Format an Int-valued GRDB column (blank for NULL) without the "Optional(...)" wrapper text.
    private static func intStr(_ v: Int?) -> String { v.map(String.init) ?? "" }

    /// Format a Double-valued GRDB column (blank for NULL). Plain decimal, `String(Double)` is
    /// round-trippable and locale-independent, which the comma-delimited CSV needs.
    private static func dblStr(_ v: Double?) -> String { v.map { String($0) } ?? "" }

    /// RFC-4180 CSV field: wrap in double quotes and double any embedded quote ONLY when the value
    /// contains a comma, quote, or newline. Used for the free-form event columns.
    private static func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Test helpers

    public func storageStats_rowCountsForTest() async throws
        -> (hr: Int, rr: Int, events: Int, battery: Int,
            spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
        // Bind each count to its own `let` before assembling the tuple. Returning the whole tuple of
        // inline `try Int.fetchOne(...) ?? 0` expressions made Swift's type-checker time out on some
        // toolchains/machines (reported by a contributor building locally); splitting it is
        // behaviour-identical and trivial to type-check.
        try syncRead { db in
            let hr = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample") ?? 0
            let rr = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval") ?? 0
            let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
            let battery = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM battery") ?? 0
            let spo2 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM spo2Sample") ?? 0
            let skinTemp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skinTempSample") ?? 0
            let resp = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM respSample") ?? 0
            let gravity = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM gravitySample") ?? 0
            return (hr, rr, events, battery, spo2, skinTemp, resp, gravity)
        }
    }

    public func stepCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stepSample") ?? 0 }
    }

    public func backfillFrontierForTest(deviceId: String, stream: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT maxTs FROM backfillFrontier WHERE deviceId = ? AND stream = ?
                """, arguments: [deviceId, stream])
        }
    }

    /// The strap's OWN banked band sleep_state samples (#175) in `[from, to]` for one device, ascending by
    /// ts. Each `(ts, state)` is the raw @81 high-nibble code (0 wake/1 still/2 asleep/3 up) carried
    /// verbatim off the offload stream. Empty when the strap never reported it (a WHOOP 4.0, or a not-yet-
    /// offloaded window). Feeds the Deep Timeline band-state track and the per-session grid the H7 guard reads.
    public func sleepStateSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [SleepStateSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, state, rawByte FROM sleepStateSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                // rawByte (v31) is the whole @81 byte; nil on any pre-v31 row. `state` is unchanged, so
                // the H7 guard and the Deep Timeline track see exactly what they saw before.
                .map { SleepStateSample(ts: $0["ts"], state: $0["state"], rawByte: $0["rawByte"]) }
        }
    }

    public func sleepStateCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sleepStateSample") ?? 0 }
    }

    /// The remaining 5/MG v18 per-second fields (v31) in `[from, to]` for one device, ascending by ts.
    /// Each row is one strap-second's slots, decoded from the compact blob by `V18AuxCodec`. Empty for a
    /// WHOOP 4.0 and for any window offloaded before v31. INSTRUMENTATION: no analytic calls this — it
    /// exists so the banked bytes are reachable for a census, and so the write path has a round-trip test.
    public func v18AuxSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [V18AuxSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, fields FROM v18AuxSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { V18AuxCodec.unpack($0["fields"] ?? Data(), ts: $0["ts"]) }
        }
    }

    public func v18AuxCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM v18AuxSample") ?? 0 }
    }

    public func ppgHrCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ppgHrSample") ?? 0 }
    }

    /// The RAW v26 optical PPG waveform (#156 follow-up), one record per second, in `[from, to]` for one
    /// device, ascending by ts. `samples` are the raw i16 ADC counts the strap sent, unpacked from the
    /// compact on-disk BLOB (`packPpgSamples`/`unpackPpgSamples`). Empty when the strap never emitted
    /// v26 (the WHOOP 4.0 / v18-only common case) or the window has no v26-heavy stretch.
    public func ppgWaveformSamples(deviceId: String, from: Int, to: Int, limit: Int = 200_000) async throws
        -> [PpgWaveformSample] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, samples, burstIndex, recordIndex FROM ppgWaveformSample
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                ORDER BY ts, recordIndex LIMIT ?
                """, arguments: [deviceId, from, to, limit])
                .map { PpgWaveformSample(ts: $0["ts"],
                                         samples: WhoopStore.unpackPpgSamples($0["samples"]),
                                         burstIndex: $0["burstIndex"],
                                         recordIndex: ($0["recordIndex"] as Int) == -1 ? nil : $0["recordIndex"]) }
        }
    }

    public func ppgWaveformCountForTest() async throws -> Int {
        try syncRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ppgWaveformSample") ?? 0 }
    }

    public func deviceRowForTest(id: String) async throws -> (mac: String?, name: String?)? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT mac, name FROM device WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return (row["mac"], row["name"])
        }
    }

    /// Write an R-R row the way a PRE-v30 build did: `ord` left NULL, emission order never recorded.
    /// The normal insert path always stamps `ord`, so there is otherwise no way to construct the
    /// legacy shape — and the read-order fallback for existing user data is exactly the branch most
    /// worth testing rather than assuming. Test-only (#823).
    public func insertLegacyRrWithoutOrdForTest(deviceId: String, ts: Int, rrMs: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO rrInterval (deviceId, ts, rrMs, seq, ord) VALUES (?, ?, ?, 0, NULL)
                ON CONFLICT(deviceId, ts, rrMs, seq) DO NOTHING
                """, arguments: [deviceId, ts, rrMs])
        }
    }

    /// The stored `ord` values for one second, in read order. Test-only (#823).
    public func rrOrdValuesForTest(deviceId: String, ts: Int) async throws -> [Int?] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ord FROM rrInterval WHERE deviceId = ? AND ts = ?
                ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC
                """, arguments: [deviceId, ts]).map { $0["ord"] }
        }
    }

    /// Every STORED R-R row for a device as `(rrMs, srcChannel)`, bypassing the scoring read's channel
    /// filter. Test-only (#1071): the fix is "filter at read, keep both channels on disk", and the only
    /// way to assert the second half is to look at the table itself rather than through `rrIntervals`.
    public func rrRowsWithChannelForTest(deviceId: String) async throws -> [(rrMs: Int, srcChannel: Int?)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT rrMs, srcChannel FROM rrInterval WHERE deviceId = ?
                ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC
                """, arguments: [deviceId]).map { (rrMs: $0["rrMs"], srcChannel: $0["srcChannel"]) }
        }
    }

    /// Run the `v35-rr-future-quarantine` backfill predicate with an EXPLICIT `now` (the migration itself
    /// uses `strftime('%s','now')`; a test needs a fixed instant). Marks every stored R-R beat whose ts is
    /// after `nowSeconds`. Test-only (#1073).
    public func markFutureRrSuspectForTest(nowSeconds: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE rrInterval SET tsSuspect = 1 WHERE ts > ?", arguments: [nowSeconds])
        }
    }

    /// Every STORED R-R row for a device as `(ts, tsSuspect)`, bypassing the scoring read's filter — so a
    /// test can assert which rows were quarantined AND that none were deleted. Test-only (#1073).
    public func rrSuspectRowsForTest(deviceId: String) async throws -> [(ts: Int, tsSuspect: Int?)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, tsSuspect FROM rrInterval WHERE deviceId = ? ORDER BY ts ASC
                """, arguments: [deviceId]).map { (ts: $0["ts"], tsSuspect: $0["tsSuspect"]) }
        }
    }
}
