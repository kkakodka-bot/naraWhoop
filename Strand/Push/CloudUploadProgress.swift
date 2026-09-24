import Foundation
import GRDB
import NoopPush

/// One value every upload-status surface reads. Row counts are measured, never estimated: the push
/// cursor is the last uploaded rowid per stream and strap, and SQLite knows how many rows sit past it.
/// Strap history sync deliberately has no percent (the strap never reports a total); cloud upload does.
struct CloudUploadProgress: Equatable {
    enum Phase: Equatable {
        case idle, queued, uploading, retrying, complete, failed
    }

    struct Backlog: Equatable {
        var pendingRows: Int
        var totalRows: Int
        var measuredAt: Date

        var uploadedRows: Int { max(0, totalRows - pendingRows) }
        /// 0...1. An empty store counts as fully uploaded so the bar never reads "0%" for "nothing to do".
        var fraction: Double {
            guard totalRows > 0 else { return 1 }
            return Double(uploadedRows) / Double(totalRows)
        }
    }

    var phase: Phase = .idle
    var acceptedBatches = 0
    var acceptedRecords = 0
    var lastError: String?
    var lastSuccessAt: Date?
    var backlog: Backlog?

    /// Passes are short and end in `retrying` whenever the bulk budget yields to strap history sync,
    /// so "active" must include retrying or the bar would vanish between every pass.
    var isActive: Bool { phase == .uploading || phase == .retrying || phase == .queued }

    static func phase(for state: CloudPushSettings.RunState) -> Phase {
        switch state {
        case .idle: return .idle
        case .queued: return .queued
        case .running, .continuing: return .uploading
        case .retrying: return .retrying
        case .complete: return .complete
        case .failed: return .failed
        }
    }

    /// Mirrors `CloudPushSettings.recordScopedRun`: a new run resets the pass counters, every other
    /// state accumulates onto them.
    mutating func apply(state: CloudPushSettings.RunState, message: String?, batches: Int, records: Int, at now: Date) {
        phase = Self.phase(for: state)
        lastError = message
        if state == .running {
            acceptedBatches = 0
            acceptedRecords = 0
        } else {
            acceptedBatches += batches
            acceptedRecords += records
        }
        if state == .complete { lastSuccessAt = now }
    }
}

/// Single publisher for upload progress. The push worker feeds it; the diagnostic card and the
/// history-sync note observe it. Backlog measurement is installed by the worker because only the worker
/// holds the account-bound database, progress store and receiver capabilities for the current run.
@MainActor
final class CloudUploadProgressCenter: ObservableObject {
    static let shared = CloudUploadProgressCenter()

    @Published private(set) var current = CloudUploadProgress()
    private var measure: (@Sendable () async throws -> CloudUploadProgress.Backlog)?
    private var refreshTask: Task<Void, Never>?

    init() {}

    nonisolated func record(state: CloudPushSettings.RunState, message: String?, batches: Int, records: Int) {
        Task { @MainActor in self.apply(state: state, message: message, batches: batches, records: records) }
    }

    func apply(state: CloudPushSettings.RunState, message: String?, batches: Int, records: Int, at now: Date = Date()) {
        current.apply(state: state, message: message, batches: batches, records: records, at: now)
        refresh()
    }

    nonisolated func install(measure: @escaping @Sendable () async throws -> CloudUploadProgress.Backlog) {
        Task { @MainActor in
            self.measure = measure
            self.refresh()
        }
    }

    /// Re-count the backlog unless a count younger than `minimumInterval` already exists.
    func refresh(minimumInterval: TimeInterval = 0, now: Date = Date()) {
        guard let measure, refreshTask == nil else { return }
        if let backlog = current.backlog, now.timeIntervalSince(backlog.measuredAt) < minimumInterval { return }
        refreshTask = Task { [weak self] in
            let backlog = try? await measure()
            guard let self else { return }
            if let backlog { self.current.backlog = backlog }
            self.refreshTask = nil
        }
    }
}

/// Counts rows the receiver has not acknowledged, per paired strap, across the streams it accepts.
/// Reuses the exact tables and cursor keys the coordinator pushes from, so the count cannot disagree
/// with what the next pass will send.
struct CloudUploadBacklogReader {
    let db: any DatabaseWriter
    let progress: CloudPushProgressStore
    let snapshot: CloudPushSnapshot
    let capabilities: PushCapabilities

    func measure() async throws -> CloudUploadProgress.Backlog {
        let live = try await snapshot.knownDeviceIds(capabilities: capabilities)
        let remembered = try await progress.knownDeviceIds()
        let devices = Set(live).union(remembered)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted()
        var pending = 0
        var total = 0
        for device in devices {
            for table in PushAppendTable.allCases where capabilities.appendTables.contains(table) {
                let after = try await progress.cursor(table: table, deviceId: device)?.rowId ?? 0
                let counts = try await count(table: CloudPushSnapshot.appendSQLName(table), deviceId: device, afterRowId: after)
                pending += counts.pending
                total += counts.total
            }
            for table in PushBinaryTable.allCases where capabilities.binaryTables.contains(table) {
                switch table {
                case .ppgWaveformSample, .v18AuxSample:
                    let after = try await progress.binaryCursor(table: table, deviceId: device)?.rowId ?? 0
                    let counts = try await count(table: table.wireName, deviceId: device, afterRowId: after)
                    pending += counts.pending
                    total += counts.total
                case .rawBatch:
                    // Raw batches have no cursor: a row is pending until the server acknowledges it.
                    let counts = try await db.read { db -> (pending: Int, total: Int) in
                        let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch WHERE deviceId = ? AND syncedAt IS NULL", arguments: [device]) ?? 0
                        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawBatch WHERE deviceId = ?", arguments: [device]) ?? 0
                        return (pending, total)
                    }
                    pending += counts.pending
                    total += counts.total
                case .rawImuSession:
                    continue // file-backed; not a row count
                }
            }
        }
        return CloudUploadProgress.Backlog(pendingRows: pending, totalRows: total, measuredAt: Date())
    }

    /// `table` comes from a closed enum, never from user input.
    private func count(table: String, deviceId: String, afterRowId: Int64) async throws -> (pending: Int, total: Int) {
        try await db.read { db in
            let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = ? AND rowid > ?", arguments: [deviceId, afterRowId]) ?? 0
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = ?", arguments: [deviceId]) ?? 0
            return (pending, total)
        }
    }
}
