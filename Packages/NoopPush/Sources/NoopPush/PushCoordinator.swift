import Foundation

/// Coordinates bounded DB snapshots and transport without holding a database read across network I/O.
public struct PushCoordinator: Sendable {
    private let source: any PushSnapshotSource
    private let transport: any PushTransport
    private let progress: any PushProgressStore
    private let sourceId: String
    private let today: @Sendable () -> Date
    private let calendar: Calendar
    private let destinationStillCurrent: @Sendable () -> Bool
    private let receiptOwner: AccountScope?
    private let objectProtocolVersion: String
    private let associateReceipt: (@Sendable (PushBinaryBatch, [PushBinaryRow], PushDurabilityReceipt) async throws -> Void)?
    private let associateInlineReceipt: (@Sendable (PushBatch, PushDurabilityReceipt) async throws -> Void)?
    private let commitSource: (@Sendable (PushSourceCommit) async throws -> Void)?
    private let prepareSelection: (@Sendable (PushPreparedSelection) async throws -> Void)?
    private let allowsPreparation: @Sendable () -> Bool
    private let allowsActivePreparation: @Sendable () -> Bool
    private let wakeBudget: PushWakeBudget?
    private let mutableIdentityNamespace: String?
    private var pressureDeferred: PushResult { .rejected(reason: "resource_pressure", retryable: true, failure: nil) }

    public init(
        source: any PushSnapshotSource,
        transport: any PushTransport,
        progress: any PushProgressStore,
        sourceId: String,
        today: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current,
        destinationStillCurrent: @escaping @Sendable () -> Bool = { true },
        receiptOwner: AccountScope? = nil,
        objectProtocolVersion: String = PushProtocol.objectVersion,
        associateReceipt: (@Sendable (PushBinaryBatch, [PushBinaryRow], PushDurabilityReceipt) async throws -> Void)? = nil,
        associateInlineReceipt: (@Sendable (PushBatch, PushDurabilityReceipt) async throws -> Void)? = nil,
        commitSource: (@Sendable (PushSourceCommit) async throws -> Void)? = nil,
        prepareSelection: (@Sendable (PushPreparedSelection) async throws -> Void)? = nil,
        allowsPreparation: @escaping @Sendable () -> Bool = { true },
        wakeBudget: PushWakeBudget? = nil,
        mutableIdentityNamespace: String? = nil
    ) {
        self.source = source
        self.transport = transport
        self.progress = progress
        self.sourceId = sourceId
        self.today = today
        self.calendar = calendar
        self.destinationStillCurrent = destinationStillCurrent
        self.receiptOwner = receiptOwner
        self.objectProtocolVersion = objectProtocolVersion
        self.associateReceipt = associateReceipt
        self.associateInlineReceipt = associateInlineReceipt
        self.commitSource = commitSource
        self.prepareSelection = prepareSelection
        self.allowsPreparation = { allowsPreparation() && (wakeBudget?.permitsPreparation ?? true) }
        self.allowsActivePreparation = { allowsPreparation() && (wakeBudget?.permitsFinishingPreparation ?? true) && destinationStillCurrent() }
        self.wakeBudget = wakeBudget
        self.mutableIdentityNamespace = mutableIdentityNamespace
    }

    public func pushAppend(_ table: PushAppendTable, deviceId: String,
                           protocolVersion: String = PushProtocol.version) async -> PushResult {
        await pushAppend(table, deviceId: deviceId, protocolVersion: protocolVersion, fresh: false)
    }

    public func pushFreshAppend(_ table: PushAppendTable, deviceId: String,
                                protocolVersion: String = PushProtocol.version) async -> PushResult {
        await pushAppend(table, deviceId: deviceId, protocolVersion: protocolVersion, fresh: true)
    }

    private func pushAppend(_ table: PushAppendTable, deviceId: String, protocolVersion: String, fresh: Bool) async -> PushResult {
        let byteLimit = fresh ? PushProtocol.freshAppendMaximumDecodedBytes : PushProtocolLimits.maxBodyBytes
        let rowLimit = min(wakeBudget?.rowsPerJob ?? PushProtocolLimits.maxRecords, fresh ? PushProtocol.freshAppendMaximumRecords : PushProtocolLimits.maxRecords)
        let kind: PushSourceCommit.Kind = fresh ? .freshAppend : .append
        guard allowsPreparation() else { return pressureDeferred }
        if !fresh, let paused = await preparationPaused(table: table.wireName, deviceId: deviceId) { return paused }
        guard wakeBudget?.admitInlinePreparation(maximumDecodedBytes: byteLimit) ?? true else { return pressureDeferred }
        let stored: PushCursor?
        do {
            stored = fresh ? try await progress.freshCursor(table: table, deviceId: deviceId)
                : try await progress.cursor(table: table, deviceId: deviceId)
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }

        let effective: PushCursor?
        if let stored, stored.rowId > 0 {
            do {
                let fingerprint = try await source.appendFingerprintAt(table: table, deviceId: deviceId, rowId: stored.rowId)
                effective = fingerprint == stored.naturalKeyFingerprint ? stored : nil
            } catch is PushProtocolException {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
            } catch {
                return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
            }
        } else {
            effective = nil
        }

        let page: PushAppendPage
        do {
            let limits = PushSourceReadLimits(maximumDecodedBytes: byteLimit, protocolVersion: protocolVersion,
                shouldContinue: allowsActivePreparation)
            if fresh {
                let clock = today().timeIntervalSince1970
                guard clock.isFinite, clock >= Double(PushProtocol.freshAppendWindowSeconds), clock < Double(Int64.max) else { throw PushSourceReadError.deferred }
                let through = Int64(clock.rounded(.down))
                page = try await source.freshAppendPage(table: table, deviceId: deviceId,
                    afterRowId: effective?.rowId ?? 0, sinceTs: through - PushProtocol.freshAppendWindowSeconds, throughTs: through,
                    limit: rowLimit + 1, limits: limits)
            } else {
                page = try await source.appendPage(table: table, deviceId: deviceId,
                    afterRowId: effective?.rowId ?? 0, limit: rowLimit + 1, limits: limits)
            }
        } catch let error as PushSourceReadError {
            if fresh { return error == .deferred ? pressureDeferred : incompatiblePreparation }
            return await sourceReadFailure(error, table: table.wireName, deviceId: deviceId)
        } catch let error as PushProtocolException {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }

        let rows = page.rows
        guard !rows.isEmpty else {
            wakeBudget?.refundEmptyPreparation(maximumDecodedBytes: byteLimit)
            return .noData
        }

        let batch: PushBatch
        do {
            guard allowsActivePreparation() else { return pressureDeferred }
            batch = try PushProtocol.appendBatch(table: table, sourceId: sourceId, deviceId: deviceId,
                startCursor: effective, records: Array(rows.prefix(rowLimit)), protocolVersion: protocolVersion,
                freshAppend: fresh, maximumDecodedBytes: byteLimit)
        } catch let error as PushProtocolException where error.errorDescription == "first append record exceeds the 4 MiB decoded batch limit" {
            if fresh { return incompatiblePreparation }
            return await sourceReadFailure(.requiresCompatibleEncoding, table: table.wireName, deviceId: deviceId)
        } catch {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        }

        if let prepareSelection {
            do {
                guard destinationStillCurrent() else { throw CancellationError() }
                try await prepareSelection(.init(inline: [batch], commit: .init(kind: kind,
                    table: table.wireName, deviceID: deviceId, batchIDs: [batch.batchId], cursor: batch.endCursor)))
            } catch { return preparationFailure() }
        }
        let accepted = await deliver(batch)
        guard case .accepted(let batchId, let recordCount, _, let batchCount) = accepted else { return accepted }
        guard let end = batch.endCursor else {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        }
        do {
            guard destinationStillCurrent() else { throw CancellationError() }
            if let commitSource {
                try await commitSource(.init(kind: kind, table: table.wireName, deviceID: deviceId,
                                              batchIDs: [batchId], cursor: end))
            } else if fresh { try await progress.saveFreshCursor(table: table, deviceId: deviceId, cursor: end) }
            else { try await progress.saveCursor(table: table, deviceId: deviceId, cursor: end) }
            return .accepted(batchId: batchId, recordCount: recordCount, hasMore: page.hasMore || rows.count > batch.recordCount, batchCount: batchCount)
        } catch let error as PushProtocolException {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }
    }

    public func pushMutable(_ table: PushMutableTable, deviceId: String) async -> PushResult {
        guard allowsPreparation() else { return pressureDeferred }
        if let paused = await preparationPaused(table: table.wireName, deviceId: deviceId) { return paused }
        guard wakeBudget?.admitInlinePreparation(maximumDecodedBytes: PushProtocolLimits.maxMutableSnapshotEncodedBytes) ?? true else { return pressureDeferred }
        var fullWindow = PushWindow.ending(today: today(), calendar: calendar)
        let previous: PushWindowProgress?
        let capturedFrontier: PushMutableFrontier?
        let journalHasMore: Bool
        do {
            previous = try await progress.window(table: table, deviceId: deviceId)
            // A time-zone database/rule change can change timestamp membership even without a
            // source UPDATE. Reset to the initial snapshot and replay the durable marker journal.
            let signature = "mutable-calendar-v1|\(calendar.identifier)|\(calendar.timeZone.identifier)|\(TimeZone.timeZoneDataVersion)"
            let prior = previous?.mutableFrontier.flatMap { $0.calendarSignature == signature ? $0 : nil }
            let page = try await source.mutableDirtyRanges(table: table, deviceId: deviceId,
                afterRevision: prior?.revision ?? 0, afterKey: prior?.key ?? "", limit: 1, calendar: calendar)
            if let page {
                if prior == nil {
                    capturedFrontier = .init(revision: 0, key: "", calendarSignature: signature)
                    journalHasMore = !page.ranges.isEmpty || page.hasMore
                } else if let range = page.ranges.first {
                    guard page.ranges.count == 1, range.revision > 0,
                          range.revision > prior!.revision || (range.revision == prior!.revision && range.key > prior!.key),
                          let from = parseDay(range.fromDay), let to = parseDay(range.toDay), from <= to,
                          to.timeIntervalSince(from) <= 3 * 86_400 else { throw PushProtocolException("invalid mutable range") }
                    fullWindow = .days(from: from, to: to, calendar: calendar)
                    capturedFrontier = .init(revision: range.revision, key: range.key, calendarSignature: signature)
                    journalHasMore = page.hasMore
                } else {
                    guard !page.hasMore else { throw PushProtocolException("empty mutable page") }
                    wakeBudget?.refundEmptyPreparation(maximumDecodedBytes: PushProtocolLimits.maxMutableSnapshotEncodedBytes)
                    return .noData
                }
            } else { capturedFrontier = nil; journalHasMore = false }
        } catch is PushSourceReadError { return pressureDeferred }
        catch { return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase)) }
        let rows: [PushMutableRecord]
        do {
            rows = try await source.mutableRows(
                table: table,
                deviceId: deviceId,
                window: fullWindow,
                limit: PushProtocolLimits.maxMutableSnapshotRecords + 1
            )
        } catch let error as PushSourceReadError {
            return await sourceReadFailure(error, table: table.wireName, deviceId: deviceId)
        } catch let error as PushProtocolException {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }

        if rows.count > PushProtocolLimits.maxMutableSnapshotRecords {
            return await sourceReadFailure(.requiresCompatibleEncoding, table: table.wireName, deviceId: deviceId)
        }

        guard allowsActivePreparation() else { return pressureDeferred }
        var encodedBytes = 0
        let days = enumerateDays(from: fullWindow.fromDay, to: fullWindow.toDay)
        var recordsByDay = Dictionary(uniqueKeysWithValues: days.map { ($0, [PushMutableRecord]()) })
        for record in rows {
            guard allowsActivePreparation() else { return pressureDeferred }
            let size: Int
            do {
                size = try PushProtocol.mutableRecordEncodedSize(table: table, record: record)
            } catch {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
            }
            encodedBytes += size
            if encodedBytes > PushProtocolLimits.maxMutableSnapshotEncodedBytes {
                return await sourceReadFailure(.requiresCompatibleEncoding, table: table.wireName, deviceId: deviceId)
            }
            let day: String
            do {
                day = try mutableRecordDay(table: table, record: record)
            } catch {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
            }
            guard recordsByDay[day] != nil else {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
            }
            recordsByDay[day, default: []].append(record)
        }

        let currentHashes: [String: String]
        do {
            var hashes: [String: String] = [:]
            for (day, dayRows) in recordsByDay {
                hashes[day] = try PushProtocol.mutableSnapshotHash(table: table, records: dayRows)
            }
            currentHashes = hashes
        } catch {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        }

        // Journal revisions must settle with an exact receipt even for a no-op UPDATE or an
        // empty deletion window. A previous content hash alone never consumes a new revision.
        let previousHashes = previous?.dayHashes ?? [:]
        let changedDays = capturedFrontier == nil ? days.filter { previousHashes[$0] != currentHashes[$0] } : days
        if changedDays.isEmpty {
            wakeBudget?.refundEmptyPreparation(maximumDecodedBytes: PushProtocolLimits.maxMutableSnapshotEncodedBytes)
            return .noData
        }

        guard let firstChanged = changedDays.first, let lastChanged = changedDays.last else { return .noData }
        let window = PushWindow.days(
            from: parseDay(firstChanged) ?? today(),
            to: parseDay(lastChanged) ?? today(),
            calendar: calendar
        )
        let changedRows = days.filter { $0 >= firstChanged && $0 <= lastChanged }
            .flatMap { recordsByDay[$0] ?? [] }

        let batches: [PushBatch]
        do {
            // A fresh source revision can return to identical values (A -> B -> A). Its
            // operation must not reuse A's earlier cached receipt. Prepared selections retain
            // this generation and exact bytes across retries; only new selection mints a nonce.
            let generation = try JSONEncoder().encode([mutableIdentityNamespace ?? sourceId,
                String(capturedFrontier?.revision ?? 0), capturedFrontier?.key ?? "",
                capturedFrontier?.calendarSignature ?? "", UUID().uuidString.lowercased()])
            batches = try PushProtocol.mutableBatches(table: table, sourceId: sourceId, deviceId: deviceId,
                window: window, records: changedRows, replacementGeneration: PushDurabilityReceipt.sha256(generation))
        } catch {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        }

        let replacementId = batches.first?.replacementId ?? batches.first?.batchId ?? ""
        let value = PushWindowProgress(window: fullWindow, batchId: replacementId, dayHashes: currentHashes, mutableFrontier: capturedFrontier)
        let sourceCommit = PushSourceCommit(kind: .mutable, table: table.wireName, deviceID: deviceId,
            batchIDs: batches.map(\.batchId), window: value)
        if let prepareSelection {
            do {
                guard destinationStillCurrent() else { throw CancellationError() }
                try await prepareSelection(.init(inline: batches, commit: sourceCommit))
            } catch { return preparationFailure() }
        }
        for batch in batches {
            let accepted = await deliver(batch)
            guard case .accepted = accepted else { return accepted }
        }

        do {
            guard destinationStillCurrent() else { throw CancellationError() }
            if let commitSource {
                try await commitSource(sourceCommit)
            } else { try await progress.saveWindow(table: table, deviceId: deviceId, progress: value) }
            return .accepted(
                batchId: replacementId,
                recordCount: changedRows.count,
                hasMore: journalHasMore,
                batchCount: batches.count
            )
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }
    }

    public func pushBinary(_ table: PushBinaryTable, deviceId: String) async -> PushResult {
        guard allowsPreparation() else { return pressureDeferred }
        // Cloud raw streams require an object manifest and typed receipt, never inline legacy ACKs.
        if receiptOwner != nil { return .rejected(reason: "use_object_lane", retryable: false, failure: nil) }
        let stored: PushCursor?
        do {
            stored = try await progress.binaryCursor(table: table, deviceId: deviceId)
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }

        let effective: PushCursor?
        if table == .rawBatch {
            effective = nil
        } else if let stored, stored.rowId > 0 {
            do {
                let atCursor = try await source.binaryRecordAt(table: table, deviceId: deviceId, rowId: stored.rowId)
                let fingerprint = atCursor.flatMap { try? PushProtocol.binaryKeyFingerprint(table: table, deviceId: deviceId, row: $0) }
                effective = fingerprint == stored.naturalKeyFingerprint ? stored : nil
            } catch is PushProtocolException {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
            } catch {
                return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
            }
        } else {
            effective = nil
        }

        let limit = table == .rawBatch ? 1 : (wakeBudget?.rowsPerJob ?? PushProtocolLimits.maxRecords) + 1
        let rows: [PushBinaryRow]
        do {
            rows = try await source.binaryRows(
                table: table,
                deviceId: deviceId,
                afterRowId: effective?.rowId ?? 0,
                limit: limit
            )
        } catch is PushProtocolException {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }

        guard !rows.isEmpty else { return .noData }

        let batch: PushBinaryBatch
        do {
            guard allowsPreparation() else { return pressureDeferred }
            batch = try PushProtocol.binaryObjectBatch(
                table: table, sourceId: sourceId, deviceId: deviceId, startCursor: effective,
                rows: Array(rows.prefix(wakeBudget?.rowsPerJob ?? PushProtocolLimits.maxRecords))
            )
        } catch {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        }

        guard wakeBudget?.admitPreparation(bytes: batch.wireBytes) ?? true else { return pressureDeferred }
        let accepted = await deliverBinary(batch)
        guard case .accepted(let batchId, let recordCount, _, let batchCount) = accepted else { return accepted }

        do {
            if let end = batch.endCursor {
                try await progress.saveBinaryCursor(table: table, deviceId: deviceId, cursor: end)
            }
            try await source.acknowledgeBinary(table: table, deviceId: deviceId, rows: rows)
            let hasMore = table != .rawBatch && rows.count > batch.sampleCount
            return .accepted(batchId: batchId, recordCount: recordCount, hasMore: hasMore, batchCount: batchCount)
        } catch is PushProtocolException {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }
    }

    /// Object-lane push (protocol 1.2): build → compress → intent → PUT direct to bucket →
    /// complete → advance cursor, only on a matching ack. Raw rows move exclusively through this
    /// lane; when the receiver advertises no lane the rows stay local.
    public func pushObjects(_ table: PushBinaryTable, deviceId: String, lane: PushObjectLane) async -> PushResult {
        guard allowsPreparation() else { return pressureDeferred }
        if let paused = await preparationPaused(table: table.wireName, deviceId: deviceId) { return paused }
        guard wakeBudget?.admitObjectPreparation() ?? true else { return pressureDeferred }
        let decodedLimit = wakeBudget?.objectDecodedBytesPerJob ?? PushProtocolLimits.maxObjectDecodedBytes
        let stored: PushCursor?
        do {
            stored = try await progress.binaryCursor(table: table, deviceId: deviceId)
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }

        let effective: PushCursor?
        if table == .rawBatch {
            effective = nil
        } else if let stored, stored.rowId > 0 {
            do {
                let fingerprint = try await source.binaryFingerprintAt(table: table, deviceId: deviceId,
                    rowId: stored.rowId, protocolVersion: objectProtocolVersion)
                effective = fingerprint == stored.naturalKeyFingerprint ? stored : nil
            } catch is PushProtocolException {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
            } catch {
                return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
            }
        } else {
            effective = nil
        }

        let limit = table == .rawBatch ? 2 : (wakeBudget?.rowsPerJob ?? PushProtocolLimits.maxRecords) + 1
        let page: PushBinaryPage
        do {
            page = try await source.binaryPage(
                table: table,
                deviceId: deviceId,
                afterRowId: effective?.rowId ?? 0,
                limit: limit, limits: .init(maximumDecodedBytes: decodedLimit,
                    protocolVersion: objectProtocolVersion, shouldContinue: allowsActivePreparation)
            )
        } catch let error as PushSourceReadError {
            return await sourceReadFailure(error, table: table.wireName, deviceId: deviceId)
        } catch is PushProtocolException {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }

        let rows = page.rows
        guard !rows.isEmpty else {
            wakeBudget?.refundEmptyPreparation(maximumDecodedBytes: decodedLimit)
            return .noData
        }

        let preparation: PushBinaryPreparation?
        do {
            // Production passes a finite wake budget. Unbudgeted legacy adapters keep their
            // existing in-memory path and cannot implicitly create account-owned spool files.
            preparation = wakeBudget == nil ? nil : try await transport.beginBinaryPreparation(maximumWireBytes: decodedLimit + 64 * 1024)
        }
        catch { return preparationFailure() }
        let batch: PushBinaryBatch
        do {
            guard allowsActivePreparation() else { throw PushSourceReadError.deferred }
            batch = try PushProtocol.binaryObjectBatch(
                table: table, sourceId: sourceId, deviceId: deviceId, startCursor: effective,
                rows: table == .rawBatch ? Array(rows.prefix(1)) : Array(rows.prefix(wakeBudget?.rowsPerJob ?? PushProtocolLimits.maxRecords)),
                protocolVersion: objectProtocolVersion,
                decodedLimit: decodedLimit, payloadDirectory: preparation?.directory,
                allowsWork: allowsActivePreparation
            )
        } catch {
            if let preparation { try? await transport.finishBinaryPreparation(preparation) }
            if error is CancellationError || (error as? PushSourceReadError) == .deferred { return pressureDeferred }
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        }

        // The negotiated ceiling is enforced before any network I/O; an object too large for the
        // advertised lane can never succeed, so do not burn an intent on it.
        guard Int64(batch.wireBytes) <= lane.maxObjectBytes else {
            if let preparation { try? await transport.finishBinaryPreparation(preparation) }
            return await sourceReadFailure(.requiresCompatibleEncoding, table: table.wireName, deviceId: deviceId)
        }

        let selected = table == .rawBatch ? Array(rows.prefix(1)) : rows.filter { row in
            guard let end = batch.endCursor else { return true }
            switch row {
            case .ppgWaveform(let r): return r.rowId <= end.rowId
            case .v18Aux(let r): return r.rowId <= end.rowId
            case .rawBatch(let r): return r.rowId <= end.rowId
            case .rawImuSession(let r): return r.rowId <= end.rowId
            }
        }
        let accepted = await deliverObject(batch, rows: selected, lane: lane)
        if let preparation { try? await transport.finishBinaryPreparation(preparation) }
        guard case .accepted(let batchId, let recordCount, _, let batchCount) = accepted else { return accepted }

        do {
            guard destinationStillCurrent() else { throw CancellationError() }
            if let commitSource {
                let rawIDs = selected.compactMap { row -> String? in
                    if case .rawBatch(let r) = row { return r.batchId }; return nil
                }
                try await commitSource(.init(kind: .binary, table: table.wireName, deviceID: deviceId,
                                              batchIDs: [batchId], cursor: batch.endCursor, rawBatchIDs: rawIDs))
            } else {
                try await source.acknowledgeBinary(table: table, deviceId: deviceId, rows: selected)
                if let end = batch.endCursor { try await progress.saveBinaryCursor(table: table, deviceId: deviceId, cursor: end) }
            }
            let hasMore = page.hasMore || rows.count > selected.count
            return .accepted(batchId: batchId, recordCount: recordCount, hasMore: hasMore, batchCount: batchCount)
        } catch is PushProtocolException {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }
    }

    private var incompatiblePreparation: PushResult {
        .rejected(reason: "compatible_encoder_required", retryable: false, failure: PushFailure(code: .localData))
    }

    private func preparationPaused(table: String, deviceId: String) async -> PushResult? {
        do {
            return try await transport.isPreparationPaused(.init(sourceID: sourceId, table: table, deviceID: deviceId))
                ? incompatiblePreparation : nil
        } catch { return preparationFailure() }
    }

    private func sourceReadFailure(_ error: PushSourceReadError, table: String, deviceId: String) async -> PushResult {
        if case .deferred = error { return pressureDeferred }
        do {
            guard destinationStillCurrent() else { throw CancellationError() }
            try await transport.pausePreparation(.init(sourceID: sourceId, table: table, deviceID: deviceId))
            return incompatiblePreparation
        } catch { return preparationFailure() }
    }

    public func pushKnownDevices(
        startDeviceIndex: Int = 0,
        startLaneIndex: Int = 0,
        startRecoveryIndex: Int = 0,
        expectedDeviceListFingerprint: String? = nil,
        maxDevices: Int = .max,
        capabilities: PushCapabilities = .all,
        binaryEnabled: Bool = false,
        pendingLanes: [PushPendingLane] = [],
        resumePreparedLane: (@Sendable (PushPendingLane) async -> PushResult)? = nil,
        allowsHistoricalPreparation: @Sendable () -> Bool = { true },
        checkpoint: (@Sendable (Int, Int, Int, String) async throws -> Void)? = nil
    ) async -> PushRunResult {
        precondition(startDeviceIndex >= 0 && startLaneIndex >= 0 && startRecoveryIndex >= 0)
        precondition(maxDevices > 0)
        guard allowsPreparation() else {
            return PushRunResult(acceptedBatches: 0, rejectedBatches: 0, hasMoreAppendRows: true,
                hasRetryableFailure: true, nextDeviceIndex: startDeviceIndex, nextLaneIndex: startLaneIndex,
                nextRecoveryIndex: startRecoveryIndex, discoveryComplete: false)
        }
        if capabilities.isEmpty && pendingLanes.isEmpty {
            return PushRunResult(acceptedBatches: 0, rejectedBatches: 0, hasMoreAppendRows: false)
        }
        let devices: [String], discoveryComplete: Bool
        do {
            let discovery = try await source.discoverDevices(capabilities: capabilities)
            discoveryComplete = discovery.isComplete
            let live = discovery.deviceIDs.filter { !$0.isBlank }.uniqued()
            for id in live { try await progress.rememberDeviceId(id) }
            let known = try await progress.knownDeviceIds()
            devices = (live + known + pendingLanes.map(\.deviceID)).filter { !$0.isBlank }.uniqued().sorted()
        } catch PushSourceReadError.deferred {
            return PushRunResult(acceptedBatches: 0, rejectedBatches: 0, hasMoreAppendRows: true,
                hasRetryableFailure: true, nextDeviceIndex: startDeviceIndex, nextLaneIndex: startLaneIndex,
                nextRecoveryIndex: startRecoveryIndex, discoveryComplete: false)
        } catch {
            return PushRunResult(acceptedBatches: 0, rejectedBatches: 1, hasMoreAppendRows: true,
                hasRetryableFailure: true, nextDeviceIndex: startDeviceIndex, nextLaneIndex: startLaneIndex,
                nextRecoveryIndex: startRecoveryIndex, discoveryComplete: false, failure: PushFailure(code: .localDatabase))
        }
        let fingerprint: String
        do { fingerprint = PushDurabilityReceipt.sha256(try JSONEncoder().encode(["fresh-history-rounds-v1"] + devices)) }
        catch { return PushRunResult(acceptedBatches: 0, rejectedBatches: 1, hasMoreAppendRows: true, hasRetryableFailure: true) }
        guard !devices.isEmpty else {
            return PushRunResult(acceptedBatches: 0, rejectedBatches: 0, hasMoreAppendRows: !discoveryComplete,
                discoveryComplete: discoveryComplete, deviceListFingerprint: fingerprint)
        }

        // Positions are stable even when capabilities or pending selections change. A saved lane
        // gets its own turn; recovery cannot consume every wake before current capture is examined.
        let appendOrder: [PushAppendTable] = [.hrSample, .gravitySample, .rrInterval, .rrPacketProvenance,
            .standardHRReceipt, .event, .battery, .spo2Sample, .skinTempSample, .respSample,
            .stepSample, .sleepStateSample, .ppgHrSample]
        let otherFresh = appendOrder.filter { $0 != .hrSample && $0 != .gravitySample }
        let historical: [(PushSourceCommit.Kind, String)] = appendOrder.map { (.append, $0.wireName) }
            + [PushMutableTable.dailyMetric, .sleepSession, .workout, .journal].map { (.mutable, $0.wireName) }
            + PushBinaryTable.allCases.map { (.binary, $0.wireName) }
        // Four-turn rounds bound the service interval of current HR/gravity independently of
        // the size or number of old backlogs. A single-request wake still grants history a turn.
        let lanes: [(PushSourceCommit.Kind, String)] = historical.enumerated().flatMap { index, old in
            [(.freshAppend, PushAppendTable.hrSample.wireName), (.freshAppend, PushAppendTable.gravitySample.wireName),
             (.freshAppend, otherFresh[index % otherFresh.count].wireName), old]
        }
        let matched = expectedDeviceListFingerprint == fingerprint
        var deviceIndex = matched ? startDeviceIndex % devices.count : 0
        var laneIndex = matched ? startLaneIndex % lanes.count : 0
        var recoveryIndex = startRecoveryIndex % 1_000_001
        let selectedDevices = Set((0..<min(maxDevices, devices.count)).map { devices[(deviceIndex + $0) % devices.count] })
        var laneTurns = 0, accepted = 0, acceptedRecords = 0, rejected = 0
        var finishedThisWake: Set<String> = [], completedSelections: Set<String> = []
        var more = !discoveryComplete, binaryMore = false, mutableMore = false, retryableFailure = false
        var selectedFailure: PushFailure?
        var stopped = false
        while laneTurns < lanes.count * devices.count && selectedDevices.contains(devices[deviceIndex]) {
            guard allowsPreparation() else { stopped = true; more = true; break }
            let device = devices[deviceIndex], lane = lanes[laneIndex]
            let laneKey = lane.0.rawValue + "\u{0}" + lane.1 + "\u{0}" + device
            let saved = pendingLanes.filter { $0.deviceID == device && $0.kind == lane.0 && $0.table == lane.1
                && !completedSelections.contains($0.selectionID) }
                .sorted { $0.selectionID < $1.selectionID }
            let result: PushResult
            var resumedID: String?
            if finishedThisWake.contains(laneKey) { result = .noData }
            else if !saved.isEmpty {
                if let resumePreparedLane {
                    let pending = saved[recoveryIndex % saved.count]
                    resumedID = pending.selectionID
                    result = await resumePreparedLane(pending)
                    recoveryIndex = (recoveryIndex + 1) % 1_000_001
                    // A second saved version or newly appended rows still need another turn.
                    more = true
                } else { result = .rejected(reason: "prepared_recovery_unavailable", retryable: true, failure: nil) }
            } else if lane.0 == .freshAppend, let table = appendOrder.first(where: { $0.wireName == lane.1 }),
                      capabilities.appendTables.contains(table) {
                result = await pushFreshAppend(table, deviceId: device, protocolVersion: capabilities.protocolVersion)
            } else if lane.0 != .freshAppend && !allowsHistoricalPreparation() {
                // Keeping debt and advancing the scheduling position does not advance a source cursor.
                more = true; result = .noData
            } else if lane.0 == .append, let table = appendOrder.first(where: { $0.wireName == lane.1 }),
                      capabilities.appendTables.contains(table) {
                result = await pushAppend(table, deviceId: device, protocolVersion: capabilities.protocolVersion)
            } else if lane.0 == .mutable, let table = PushMutableTable.allCases.first(where: { $0.wireName == lane.1 }),
                      capabilities.mutableTables.contains(table) {
                result = await pushMutable(table, deviceId: device)
            } else if lane.0 == .binary, binaryEnabled,
                      let table = PushBinaryTable.allCases.first(where: { $0.wireName == lane.1 }),
                      capabilities.binaryTables.contains(table), let objectLane = capabilities.objectLane,
                      objectLane.streams.contains(table) {
                result = await pushObjects(table, deviceId: device, lane: objectLane)
            } else { result = .noData }
            let attemptedWork: Bool
            switch result {
            case .accepted(_, let records, let hasMore, let batchCount):
                attemptedWork = true
                if let resumedID { completedSelections.insert(resumedID) }
                if !hasMore && saved.count <= 1 { finishedThisWake.insert(laneKey) }
                accepted += batchCount; acceptedRecords += records
                if lane.0 == .mutable { mutableMore = mutableMore || hasMore }
                else if lane.0 == .binary { binaryMore = binaryMore || hasMore }
                else { more = more || hasMore }
            case .rejected(_, let retryable, let failure):
                attemptedWork = true
                finishedThisWake.insert(laneKey)
                rejected += 1; more = true
                if selectedFailure == nil || (retryable && !retryableFailure) {
                    if let table = PushAppendTable.allCases.first(where: { $0.wireName == lane.1 }) { selectedFailure = failure?.attributed(to: table) }
                    else if let table = PushMutableTable.allCases.first(where: { $0.wireName == lane.1 }) { selectedFailure = failure?.attributed(to: table) }
                    else if let table = PushBinaryTable.allCases.first(where: { $0.wireName == lane.1 }) { selectedFailure = failure?.attributed(to: table) }
                    else { selectedFailure = failure }
                }
                retryableFailure = retryableFailure || retryable
            case .noData: attemptedWork = false; finishedThisWake.insert(laneKey)
            }
            laneTurns += 1; laneIndex += 1
            if laneIndex % 4 == 0 {
                deviceIndex = (deviceIndex + 1) % devices.count
                if deviceIndex != 0 { laneIndex -= 4 }
                else if laneIndex == lanes.count { laneIndex = 0 }
            }
            // Persist after failures as well as success. A poisoned lane cannot freeze the prefix.
            do {
                if attemptedWork || laneIndex % 4 == 0 { try await checkpoint?(deviceIndex, laneIndex, recoveryIndex, fingerprint) }
            }
            catch { rejected += 1; retryableFailure = true; more = true; stopped = true; break }
            if deviceIndex == 0 && laneIndex == 0 { break }
        }
        return PushRunResult(acceptedBatches: accepted, rejectedBatches: rejected, hasMoreAppendRows: more,
            hasMoreBinaryRows: binaryMore, hasMoreMutableRows: mutableMore, acceptedRecords: acceptedRecords,
            hasRetryableFailure: retryableFailure, nextDeviceIndex: deviceIndex, nextLaneIndex: laneIndex,
            nextRecoveryIndex: recoveryIndex, discoveryComplete: discoveryComplete, deviceListFingerprint: fingerprint,
            hasMoreDevices: stopped || selectedDevices.count < devices.count || !discoveryComplete, failure: selectedFailure)
    }

    private func deliverBinary(_ batch: PushBinaryBatch) async -> PushResult {
        guard wakeBudget?.admitRequest(bytes: batch.wireBytes) ?? true else { return pressureDeferred }
        guard destinationStillCurrent() else {
            return .rejected(reason: "cancelled", retryable: true, failure: nil)
        }
        let response: PushTransportResponse
        do {
            response = try await transport.postBinary(batch)
        } catch let error as PushTransportException {
            return .rejected(reason: error.failure.safeCode, retryable: error.failure.retryable, failure: error.failure)
        } catch {
            return .rejected(reason: PushFailure(code: .networkIO).safeCode, retryable: true, failure: PushFailure(code: .networkIO))
        }

        if response.body.count > PushProtocolLimits.maxAckBytes {
            return .rejected(reason: PushFailure(code: .ackInvalid).safeCode, retryable: false, failure: PushFailure(code: .ackInvalid))
        }
        if response.statusCode < 200 || response.statusCode > 299 {
            let failure = PushError.httpFailure(
                status: response.statusCode,
                body: response.body, expectedVersion: batch.protocolVersion, table: batch.table
            )
            return .rejected(reason: failure.safeCode, retryable: failure.retryable, failure: failure)
        }
        let ack: PushAck
        do {
            ack = try PushAck.parse(response.body)
        } catch {
            return .rejected(reason: PushFailure(code: .ackInvalid).safeCode, retryable: false, failure: PushFailure(code: .ackInvalid))
        }
        guard ack.exactlyMatches(batch) else {
            return .rejected(reason: PushFailure(code: .ackInvalid).safeCode, retryable: false, failure: PushFailure(code: .ackInvalid))
        }
        return .accepted(batchId: batch.batchId, recordCount: batch.sampleCount, hasMore: false)
    }

    /// Replays the saved operation without consulting the current snapshot, calendar or compressor.
    /// The application must use the selection's original progress namespace and hold its lane.
    public func resumePrepared(_ selection: PushPreparedSelection, manifestOverride: PushObjectManifest? = nil) async -> PushResult {
        guard destinationStillCurrent(), selection.sourceID == sourceId, let commitSource else { return preparationFailure() }
        do {
            var records = 0
            if let object = try selection.restoredObject() {
                let manifest = manifestOverride ?? object.manifest
                guard manifest == object.manifest.replacingObjectId(manifest.objectId) else { return preparationFailure() }
                let result = await deliverObject(object.batch, rows: object.rows, lane: object.lane, restoredManifest: manifest)
                guard case .accepted = result else { return result }
                records = object.batch.sampleCount
            } else {
                for batch in try selection.restoredInlineBatches() {
                    let result = await deliver(batch)
                    guard case .accepted = result else { return result }
                    records += batch.recordCount
                }
            }
            guard destinationStillCurrent() else { throw CancellationError() }
            try await commitSource(selection.commit)
            return .accepted(batchId: selection.commit.window?.batchId ?? selection.batchIDs[0],
                recordCount: records, hasMore: false, batchCount: selection.batchIDs.count)
        } catch { return preparationFailure() }
    }

    private func preparationFailure() -> PushResult {
        .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
    }

    private func uploadObject(_ intent: PushObjectIntent, batch: PushBinaryBatch) async throws {
        if let file = batch.payloadFile { try await transport.uploadObject(intent, file: file) }
        else { try await transport.uploadObject(intent, body: batch.payload) }
    }

    private func deliverObject(_ batch: PushBinaryBatch, rows: [PushBinaryRow], lane: PushObjectLane,
                               restoredManifest: PushObjectManifest? = nil) async -> PushResult {
        guard destinationStillCurrent() else {
            return .rejected(reason: "cancelled", retryable: true, failure: nil)
        }

        var manifest = restoredManifest ?? PushObjectManifest(batch: batch)
        var uploaded = false
        var expectedKey: String? = nil

        // Resume bookkeeping for an interrupted attempt. A persisted record whose identity no
        // longer matches the rebuilt object is stale (local data changed) and is dropped; a
        // matching one lets us skip straight to complete when the PUT already landed.
        do {
            if restoredManifest == nil, let inFlight = try await progress.inFlightObject(table: batch.table, deviceId: batch.deviceId) {
                if inFlight.contentSha256 == manifest.contentSha256 &&
                    (batch.payloadFile == nil || inFlight.objectId == manifest.objectId) {
                    manifest = manifest.replacingObjectId(inFlight.objectId)
                    uploaded = inFlight.uploaded
                    expectedKey = inFlight.objectKey
                } else {
                    try await progress.saveInFlightObject(table: batch.table, deviceId: batch.deviceId, object: nil)
                }
            }
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }

        if restoredManifest == nil, let prepareSelection {
            let rawIDs = rows.compactMap { row -> String? in if case .rawBatch(let r) = row { return r.batchId }; return nil }
            do {
                guard destinationStillCurrent() else { throw CancellationError() }
                try await prepareSelection(.init(binary: batch, rows: rows, manifest: manifest, lane: lane,
                    commit: .init(kind: .binary, table: batch.wireName, deviceID: batch.deviceId,
                        batchIDs: [batch.batchId], cursor: batch.endCursor, rawBatchIDs: rawIDs)))
            } catch { return preparationFailure() }
        }

        if !uploaded {
            let intent: PushObjectIntent
            guard destinationStillCurrent() else {
                return .rejected(reason: "cancelled", retryable: true, failure: nil)
            }
            do {
                guard wakeBudget?.admitRequest(bytes: 8 * 1024) ?? true else { return pressureDeferred }
                intent = try await transport.createObjectIntent(manifest, lane: lane)
            } catch let error as PushTransportException where receiptOwner == nil && error.failure.receiverCode == "object_id_conflict" {
                // Same id, different bytes: the id is burned server-side. Mint a fresh one and
                // retry exactly once; a second conflict means something is deeply wrong.
                manifest = manifest.replacingObjectId(PushProtocol.freshObjectId())
                guard destinationStillCurrent() else {
                    return .rejected(reason: "cancelled", retryable: true, failure: nil)
                }
                do {
                    guard wakeBudget?.admitRequest(bytes: 8 * 1024) ?? true else { return pressureDeferred }
                    intent = try await transport.createObjectIntent(manifest, lane: lane)
                } catch {
                    return objectLaneFailure(error)
                }
            } catch {
                return objectLaneFailure(error)
            }

            guard intent.objectId == manifest.objectId else {
                return .rejected(reason: PushFailure(code: .ackInvalid).safeCode, retryable: false, failure: PushFailure(code: .ackInvalid))
            }
            if !intent.duplicate, let resumedKey = expectedKey, intent.objectKey != resumedKey {
                // The receiver moved an incomplete object to a new key; resume must not fork.
                return .rejected(reason: PushFailure(code: .ackInvalid).safeCode, retryable: false, failure: PushFailure(code: .ackInvalid))
            }
            expectedKey = intent.objectKey

            // Persist before the PUT so a kill mid-upload resumes onto the same objectKey.
            do {
                try await progress.saveInFlightObject(
                    table: batch.table, deviceId: batch.deviceId,
                    object: PushInFlightObject(
                        objectId: manifest.objectId, objectKey: intent.objectKey,
                        contentSha256: manifest.contentSha256, uploaded: false
                    )
                )
            } catch {
                return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
            }

            guard destinationStillCurrent() else {
                return .rejected(reason: "cancelled", retryable: true, failure: nil)
            }
            do {
                guard wakeBudget?.admitRequest(bytes: batch.wireBytes, savedObject: restoredManifest != nil) ?? true else { return pressureDeferred }
                try await uploadObject(intent, batch: batch)
            } catch {
                // Keep the in-flight record: the next run re-intents for a fresh URL onto the
                // same objectKey rather than minting a new object.
                return objectLaneFailure(error)
            }
            do {
                try await progress.saveInFlightObject(
                    table: batch.table, deviceId: batch.deviceId,
                    object: PushInFlightObject(
                        objectId: manifest.objectId, objectKey: intent.objectKey,
                        contentSha256: manifest.contentSha256, uploaded: true
                    )
                )
            } catch {
                return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
            }
        }

        var reuploaded = false
        while true {
            let ack: PushObjectAck
            guard destinationStillCurrent() else {
                return .rejected(reason: "cancelled", retryable: true, failure: nil)
            }
            do {
                guard wakeBudget?.admitRequest(bytes: 0) ?? true else { return pressureDeferred }
                ack = try await transport.completeObject(objectId: manifest.objectId, lane: lane)
            } catch let error as PushTransportException {
                let code = error.failure.receiverCode
                if receiptOwner == nil, !reuploaded, code == "size_mismatch" || code == "object_missing" {
                    // The bytes at the bucket are missing or short of what the intent committed:
                    // re-sign the same objectId and re-PUT exactly once.
                    reuploaded = true
                    guard destinationStillCurrent() else {
                        return .rejected(reason: "cancelled", retryable: true, failure: nil)
                    }
                    do {
                        guard wakeBudget?.admitRequest(bytes: 8 * 1024) ?? true else { return pressureDeferred }
                        let refreshed = try await transport.createObjectIntent(manifest, lane: lane)
                        if refreshed.duplicate { continue } // became ready meanwhile → complete again
                        guard refreshed.objectId == manifest.objectId else {
                            return .rejected(reason: PushFailure(code: .ackInvalid).safeCode, retryable: false, failure: PushFailure(code: .ackInvalid))
                        }
                        guard destinationStillCurrent() else {
                            return .rejected(reason: "cancelled", retryable: true, failure: nil)
                        }
                        guard wakeBudget?.admitRequest(bytes: batch.wireBytes, savedObject: restoredManifest != nil) ?? true else { return pressureDeferred }
                        try await uploadObject(refreshed, batch: batch)
                        expectedKey = refreshed.objectKey
                    } catch {
                        return objectLaneFailure(error)
                    }
                    continue
                }
                return objectLaneFailure(error)
            } catch {
                return objectLaneFailure(error)
            }

            guard destinationStillCurrent(), let receiptOwner,
                  ack.objectId == manifest.objectId, ack.releasesLocalRows,
                  ack.protocolVersion == manifest.protocolVersion,
                  let receipt = ack.durabilityReceipt,
                  receipt.matches(manifest, owner: receiptOwner,
                                  wireSHA256: batch.wireSHA256, wireBytes: batch.wireBytes) else {
                return .rejected(reason: PushFailure(code: .ackInvalid).safeCode, retryable: false, failure: PushFailure(code: .ackInvalid))
            }
            do {
                guard let associateReceipt else { throw PushProtocolException("missing source receipt association") }
                try await associateReceipt(batch, rows, receipt)
                guard destinationStillCurrent() else { throw CancellationError() }
            } catch {
                return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
            }
            return .accepted(batchId: batch.batchId, recordCount: batch.sampleCount, hasMore: false)
        }
    }

    private func objectLaneFailure(_ error: Error) -> PushResult {
        if let error = error as? PushTransportException {
            return .rejected(reason: error.failure.safeCode, retryable: error.failure.retryable, failure: error.failure)
        }
        return .rejected(reason: PushFailure(code: .networkIO).safeCode, retryable: true, failure: PushFailure(code: .networkIO))
    }

    private func deliver(_ batch: PushBatch) async -> PushResult {
        guard wakeBudget?.admitRequest(bytes: batch.body.count) ?? true else { return pressureDeferred }
        guard destinationStillCurrent() else {
            return .rejected(reason: "cancelled", retryable: true, failure: nil)
        }
        let response: PushTransportResponse
        do {
            response = try await transport.post(batch)
        } catch let error as PushTransportException {
            return .rejected(reason: error.failure.safeCode, retryable: error.failure.retryable, failure: error.failure)
        } catch {
            return .rejected(reason: PushFailure(code: .networkIO).safeCode, retryable: true, failure: PushFailure(code: .networkIO))
        }

        if response.body.count > PushProtocolLimits.maxAckBytes {
            return .rejected(reason: PushFailure(code: .ackInvalid).safeCode, retryable: false, failure: PushFailure(code: .ackInvalid))
        }
        if response.statusCode < 200 || response.statusCode > 299 {
            let failure = PushError.httpFailure(
                status: response.statusCode,
                body: response.body, expectedVersion: batch.protocolVersion, table: batch.table
            )
            return .rejected(reason: failure.safeCode, retryable: failure.retryable, failure: failure)
        }
        let ack: PushAck
        do {
            ack = try PushAck.parse(response.body)
        } catch {
            return .rejected(reason: PushFailure(code: .ackInvalid).safeCode, retryable: false, failure: PushFailure(code: .ackInvalid))
        }
        guard ack.exactlyMatches(batch) else {
            return .rejected(reason: PushFailure(code: .ackInvalid).safeCode, retryable: false, failure: PushFailure(code: .ackInvalid))
        }
        if let receiptOwner, ack.durabilityReceipt?.matches(batch, owner: receiptOwner) != true {
            return .rejected(reason: PushFailure(code: .ackInvalid).safeCode, retryable: false, failure: PushFailure(code: .ackInvalid))
        }
        if receiptOwner != nil {
            do {
                guard destinationStillCurrent(), let receipt = ack.durabilityReceipt, let associateInlineReceipt else {
                    throw PushProtocolException("missing inline receipt association")
                }
                try await associateInlineReceipt(batch, receipt)
            } catch { return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase)) }
        }
        return .accepted(batchId: batch.batchId, recordCount: batch.recordCount, hasMore: false)
    }

    private func mutableRecordDay(table: PushMutableTable, record: PushMutableRecord) throws -> String {
        switch table {
        case .dailyMetric, .journal:
            guard case .string(let day) = record.key["day"], !day.isEmpty else {
                throw PushProtocolException("mutable day key is not a string")
            }
            guard parseDay(day) != nil else {
                throw PushProtocolException("mutable day key is invalid")
            }
            return day
        case .sleepSession, .workout:
            guard let timestamp = record.key["startTs"]?.int64Value else {
                throw PushProtocolException("mutable startTs key is not an integer")
            }
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = calendar.timeZone
            return formatter.string(from: date)
        }
    }

    private func enumerateDays(from: String, to: String) -> [String] {
        guard var current = parseDay(from), let end = parseDay(to) else { return [] }
        var days: [String] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        while current <= end {
            days.append(formatter.string(from: current))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }

    private func parseDay(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        formatter.isLenient = false
        guard let date = formatter.date(from: day), formatter.string(from: date) == day else { return nil }
        return date
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
