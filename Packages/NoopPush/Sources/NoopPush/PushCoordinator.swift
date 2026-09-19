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
        allowsPreparation: @escaping @Sendable () -> Bool = { true }
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
        self.allowsPreparation = allowsPreparation
    }

    public func pushAppend(_ table: PushAppendTable, deviceId: String,
                           protocolVersion: String = PushProtocol.version) async -> PushResult {
        guard allowsPreparation() else { return pressureDeferred }
        let stored: PushCursor?
        do {
            stored = try await progress.cursor(table: table, deviceId: deviceId)
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }

        let effective: PushCursor?
        if let stored, stored.rowId > 0 {
            do {
                let atCursor = try await source.appendRecordAt(table: table, deviceId: deviceId, rowId: stored.rowId)
                let fingerprint = atCursor.flatMap { try? PushProtocol.keyFingerprint(table: table, deviceId: deviceId, key: $0.key) }
                effective = fingerprint == stored.naturalKeyFingerprint ? stored : nil
            } catch is PushProtocolException {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
            } catch {
                return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
            }
        } else {
            effective = nil
        }

        let rows: [PushAppendRecord]
        do {
            rows = try await source.appendRows(
                table: table,
                deviceId: deviceId,
                afterRowId: effective?.rowId ?? 0,
                limit: PushProtocolLimits.maxRecords + 1
            )
        } catch let error as PushProtocolException {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }

        guard !rows.isEmpty else { return .noData }

        let batch: PushBatch
        do {
            guard allowsPreparation() else { return pressureDeferred }
            batch = try PushProtocol.appendBatch(table: table, sourceId: sourceId, deviceId: deviceId,
                startCursor: effective, records: rows, protocolVersion: protocolVersion)
        } catch {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        }

        if let prepareSelection {
            do {
                guard destinationStillCurrent() else { throw CancellationError() }
                try await prepareSelection(.init(inline: [batch], commit: .init(kind: .append,
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
                try await commitSource(.init(kind: .append, table: table.wireName, deviceID: deviceId,
                                              batchIDs: [batchId], cursor: end))
            } else { try await progress.saveCursor(table: table, deviceId: deviceId, cursor: end) }
            return .accepted(batchId: batchId, recordCount: recordCount, hasMore: rows.count > batch.recordCount, batchCount: batchCount)
        } catch let error as PushProtocolException {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }
    }

    public func pushMutable(_ table: PushMutableTable, deviceId: String) async -> PushResult {
        guard allowsPreparation() else { return pressureDeferred }
        if table == .eventLabel {
            return await pushEventLabels(deviceId: deviceId)
        }
        let fullWindow = PushWindow.ending(today: today(), calendar: calendar)
        let rows: [PushMutableRecord]
        do {
            rows = try await source.mutableRows(
                table: table,
                deviceId: deviceId,
                window: fullWindow,
                limit: PushProtocolLimits.maxMutableSnapshotRecords + 1
            )
        } catch let error as PushProtocolException {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }

        if rows.count > PushProtocolLimits.maxMutableSnapshotRecords {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        }

        guard allowsPreparation() else { return pressureDeferred }
        var encodedBytes = 0
        let days = enumerateDays(from: fullWindow.fromDay, to: fullWindow.toDay)
        var recordsByDay = Dictionary(uniqueKeysWithValues: days.map { ($0, [PushMutableRecord]()) })
        for record in rows {
            guard allowsPreparation() else { return pressureDeferred }
            let size: Int
            do {
                size = try PushProtocol.mutableRecordEncodedSize(table: table, record: record)
            } catch {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
            }
            encodedBytes += size
            if encodedBytes > PushProtocolLimits.maxMutableSnapshotEncodedBytes {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
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

        let previousHashes: [String: String]
        do {
            previousHashes = try await progress.window(table: table, deviceId: deviceId)?.dayHashes ?? [:]
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }

        let changedDays = days.filter { previousHashes[$0] != currentHashes[$0] }
        if changedDays.isEmpty { return .noData }

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
            batches = try PushProtocol.mutableBatches(table: table, sourceId: sourceId, deviceId: deviceId, window: window, records: changedRows)
        } catch {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        }

        let replacementId = batches.first?.replacementId ?? batches.first?.batchId ?? ""
        let value = PushWindowProgress(window: fullWindow, batchId: replacementId, dayHashes: currentHashes)
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
                hasMore: false,
                batchCount: batches.count
            )
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }
    }

    /// Event labels are editable long after they began, so the ordinary 14-day horizon is not
    /// sufficient. UTC-day partitions keep every authoritative replacement bounded while retained
    /// hashes make edits and deletions converge for the full history.
    private func pushEventLabels(deviceId: String) async -> PushResult {
        let currentKeys: Set<String>
        let prior: PushWindowProgress?
        do {
            currentKeys = Set(try await source.mutablePartitionKeys(table: .eventLabel, deviceId: deviceId))
            prior = try await progress.window(table: .eventLabel, deviceId: deviceId)
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }
        let priorKeys = Set(prior?.dayHashes.keys.map { $0 } ?? [])
        let partitionKeys = currentKeys.union(priorKeys).sorted()
        guard !partitionKeys.isEmpty else { return .noData }

        var currentHashes: [String: String] = [:]
        var acceptedRecords = 0
        var acceptedBatches = 0
        var resultBatchId = prior?.batchId ?? ""
        var progressWindow = prior?.window

        for key in partitionKeys {
            guard let window = eventLabelWindow(dayKey: key) else {
                // Ignore progress sent by the pre-partition event-label implementation; current
                // UTC day keys will establish bounded progress on this run.
                continue
            }
            let rows: [PushMutableRecord]
            do {
                rows = try await source.mutableRows(
                    table: .eventLabel,
                    deviceId: deviceId,
                    window: window,
                    limit: PushProtocolLimits.maxMutableSnapshotRecords + 1
                )
                guard rows.count <= PushProtocolLimits.maxMutableSnapshotRecords else {
                    throw PushProtocolException("event-label UTC day exceeds the mutable snapshot record limit")
                }
                let encodedBytes = try rows.reduce(into: 0) { total, row in
                    total += try PushProtocol.mutableRecordEncodedSize(table: .eventLabel, record: row)
                }
                guard encodedBytes <= PushProtocolLimits.maxMutableSnapshotEncodedBytes else {
                    throw PushProtocolException("event-label UTC day exceeds the mutable snapshot byte limit")
                }
            } catch is PushProtocolException {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
            } catch {
                return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
            }

            let hash: String
            do {
                hash = try PushProtocol.mutableSnapshotHash(table: .eventLabel, records: rows)
            } catch {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
            }
            if currentKeys.contains(key) { currentHashes[key] = hash }
            guard prior?.dayHashes[key] != hash else { continue }

            let batches: [PushBatch]
            do {
                batches = try PushProtocol.mutableBatches(
                    table: .eventLabel,
                    sourceId: sourceId,
                    deviceId: deviceId,
                    window: window,
                    records: rows,
                    protocolVersion: PushProtocol.objectVersion
                )
            } catch {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
            }
            for batch in batches {
                let accepted = await deliver(batch)
                guard case .accepted = accepted else { return accepted }
            }
            resultBatchId = batches.first?.replacementId ?? batches.first?.batchId ?? resultBatchId
            progressWindow = window
            acceptedRecords += rows.count
            acceptedBatches += batches.count
        }

        guard acceptedBatches > 0, let progressWindow else { return .noData }
        do {
            try await progress.saveWindow(
                table: .eventLabel,
                deviceId: deviceId,
                progress: PushWindowProgress(window: progressWindow, batchId: resultBatchId, dayHashes: currentHashes)
            )
            return .accepted(
                batchId: resultBatchId,
                recordCount: acceptedRecords,
                hasMore: false,
                batchCount: acceptedBatches
            )
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }
    }

    private func eventLabelWindow(dayKey: String) -> PushWindow? {
        let fields = dayKey.split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let start = utc.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2])),
              let end = utc.date(byAdding: .day, value: 1, to: start) else { return nil }
        return PushWindow(
            fromDay: dayKey,
            toDay: dayKey,
            startTsInclusive: Int64(start.timeIntervalSince1970),
            endTsExclusive: Int64(end.timeIntervalSince1970)
        )
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

        let limit = table == .rawBatch ? 1 : PushProtocolLimits.maxRecords + 1
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
                table: table, sourceId: sourceId, deviceId: deviceId, startCursor: effective, rows: rows
            )
        } catch {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        }

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
                let fingerprint = atCursor.flatMap { try? PushProtocol.binaryKeyFingerprint(table: table, deviceId: deviceId,
                    row: $0, v18IdentityV2: objectProtocolVersion == PushProtocol.auxiliaryIdentityVersion) }
                effective = fingerprint == stored.naturalKeyFingerprint ? stored : nil
            } catch is PushProtocolException {
                return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
            } catch {
                return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
            }
        } else {
            effective = nil
        }

        let limit = table == .rawBatch ? 2 : PushProtocolLimits.maxRecords + 1
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
                rows: table == .rawBatch ? Array(rows.prefix(1)) : rows,
                protocolVersion: objectProtocolVersion,
                decodedLimit: PushProtocolLimits.maxObjectDecodedBytes
            )
        } catch {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        }

        // The negotiated ceiling is enforced before any network I/O; an object too large for the
        // advertised lane can never succeed, so do not burn an intent on it.
        guard Int64(batch.payload.count) <= lane.maxObjectBytes else {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
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
            let hasMore = rows.count > selected.count
            return .accepted(batchId: batchId, recordCount: recordCount, hasMore: hasMore, batchCount: batchCount)
        } catch is PushProtocolException {
            return .rejected(reason: PushFailure(code: .localData).safeCode, retryable: false, failure: PushFailure(code: .localData))
        } catch {
            return .rejected(reason: PushFailure(code: .localDatabase).safeCode, retryable: true, failure: PushFailure(code: .localDatabase))
        }
    }

    public func pushKnownDevices(
        startDeviceIndex: Int = 0,
        maxDevices: Int = .max,
        capabilities: PushCapabilities = .all,
        binaryEnabled: Bool = false
    ) async -> PushRunResult {
        precondition(startDeviceIndex >= 0)
        precondition(maxDevices > 0)
        guard allowsPreparation() else {
            return PushRunResult(acceptedBatches: 0, rejectedBatches: 0, hasMoreAppendRows: true,
                                 hasRetryableFailure: true)
        }
        let ndjsonEnabled = !capabilities.appendTables.isEmpty || !capabilities.mutableTables.isEmpty
        let binaryAllowed = binaryEnabled && !capabilities.binaryTables.isEmpty
        if capabilities.isEmpty || (!ndjsonEnabled && !binaryAllowed) {
            return PushRunResult(acceptedBatches: 0, rejectedBatches: 0, hasMoreAppendRows: false)
        }

        let devices: [String]
        do {
            let live = try await source.knownDeviceIds(capabilities: capabilities).filter { !$0.isBlank }.uniqued()
            for id in live { try await progress.rememberDeviceId(id) }
            let known = try await progress.knownDeviceIds()
            devices = (live + known).filter { !$0.isBlank }.uniqued().sorted()
        } catch {
            let failure = PushFailure(code: .localDatabase)
            return PushRunResult(
                acceptedBatches: 0, rejectedBatches: 1, hasMoreAppendRows: false,
                hasRetryableFailure: true, failure: failure
            )
        }

        guard !devices.isEmpty else {
            return PushRunResult(acceptedBatches: 0, rejectedBatches: 0, hasMoreAppendRows: false)
        }

        let start = startDeviceIndex % devices.count
        let selectedCount = min(maxDevices, devices.count)
        let selectedDevices = (0..<selectedCount).map { devices[(start + $0) % devices.count] }
        let nextDeviceIndex = (start + selectedCount) % devices.count

        var accepted = 0
        var acceptedRecords = 0
        var rejected = 0
        var more = false
        var binaryMore = false
        var retryableFailure = false
        var selectedFailure: PushFailure?

        // Wake-budget ordering: ship scored mutable tables first so a short background wake still
        // lands today's Charge / sleep / workouts / journal before dense per-second append streams.
        // Append tables follow: lightweight event + battery, then the heavy HR/SpO₂/temp/resp/gravity
        // lanes, with rrInterval last among append tables. Binary/object lanes stay last.
        let mutableOrder: [PushMutableTable] = [.dailyMetric, .sleepSession, .workout, .journal]
        let appendOrder: [PushAppendTable] = [
            .event, .battery, .hrSample, .spo2Sample, .skinTempSample,
            .respSample, .gravitySample, .stepSample, .sleepStateSample, .ppgHrSample,
            .rrInterval, .rrPacketProvenance, .standardHRReceipt,
        ]

        for deviceId in selectedDevices {
            if ndjsonEnabled {
                for table in mutableOrder where capabilities.mutableTables.contains(table) {
                    switch await pushMutable(table, deviceId: deviceId) {
                    case .accepted(_, let records, _, let batchCount):
                        accepted += batchCount
                        acceptedRecords += records
                    case .rejected(_, let retryable, let failure):
                        rejected += 1
                        if selectedFailure == nil || (retryable && !retryableFailure) {
                            selectedFailure = failure?.attributed(to: table)
                        }
                        retryableFailure = retryableFailure || retryable
                    case .noData:
                        break
                    }
                }
                for table in appendOrder where capabilities.appendTables.contains(table) {
                    switch await pushAppend(table, deviceId: deviceId, protocolVersion: capabilities.protocolVersion) {
                    case .accepted(_, let records, let hasMore, let batchCount):
                        accepted += batchCount
                        acceptedRecords += records
                        more = more || hasMore
                    case .rejected(_, let retryable, let failure):
                        rejected += 1
                        if selectedFailure == nil || (retryable && !retryableFailure) {
                            selectedFailure = failure?.attributed(to: table)
                        }
                        retryableFailure = retryableFailure || retryable
                    case .noData:
                        break
                    }
                }
            }
            if binaryAllowed {
                for table in PushBinaryTable.allCases where capabilities.binaryTables.contains(table) {
                    // Raw streams move only over the advertised object lane. With no lane the rows
                    // stay local: the inline endpoint refuses them with `use_object_lane` and a
                    // retry loop would burn battery on a refusal the client cannot act on.
                    guard let lane = capabilities.objectLane, lane.streams.contains(table) else { continue }
                    switch await pushObjects(table, deviceId: deviceId, lane: lane) {
                    case .accepted(_, let records, let hasMore, let batchCount):
                        accepted += batchCount
                        acceptedRecords += records
                        binaryMore = binaryMore || hasMore
                    case .rejected(_, let retryable, let failure):
                        rejected += 1
                        if selectedFailure == nil || (retryable && !retryableFailure) {
                            selectedFailure = failure?.attributed(to: table)
                        }
                        retryableFailure = retryableFailure || retryable
                    case .noData:
                        break
                    }
                }
            }
        }

        return PushRunResult(
            acceptedBatches: accepted,
            rejectedBatches: rejected,
            hasMoreAppendRows: more,
            hasMoreBinaryRows: binaryMore,
            acceptedRecords: acceptedRecords,
            hasRetryableFailure: retryableFailure,
            nextDeviceIndex: nextDeviceIndex,
            hasMoreDevices: devices.count > selectedCount,
            failure: selectedFailure
        )
    }

    private func deliverBinary(_ batch: PushBinaryBatch) async -> PushResult {
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
                if inFlight.contentSha256 == manifest.contentSha256 {
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
                intent = try await transport.createObjectIntent(manifest, lane: lane)
            } catch let error as PushTransportException where receiptOwner == nil && error.failure.receiverCode == "object_id_conflict" {
                // Same id, different bytes: the id is burned server-side. Mint a fresh one and
                // retry exactly once; a second conflict means something is deeply wrong.
                manifest = manifest.replacingObjectId(PushProtocol.freshObjectId())
                guard destinationStillCurrent() else {
                    return .rejected(reason: "cancelled", retryable: true, failure: nil)
                }
                do {
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
                try await transport.uploadObject(intent, body: batch.payload)
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
                        let refreshed = try await transport.createObjectIntent(manifest, lane: lane)
                        if refreshed.duplicate { continue } // became ready meanwhile → complete again
                        guard refreshed.objectId == manifest.objectId else {
                            return .rejected(reason: PushFailure(code: .ackInvalid).safeCode, retryable: false, failure: PushFailure(code: .ackInvalid))
                        }
                        guard destinationStillCurrent() else {
                            return .rejected(reason: "cancelled", retryable: true, failure: nil)
                        }
                        try await transport.uploadObject(refreshed, body: batch.payload)
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
                                  wireSHA256: PushDurabilityReceipt.sha256(batch.payload), wireBytes: batch.payload.count) else {
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
