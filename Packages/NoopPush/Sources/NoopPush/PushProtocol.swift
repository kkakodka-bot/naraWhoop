import Foundation
import CryptoKit

public struct PushProtocolException: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum PushProtocol {
    public static let version = "1.0"
    public static let binaryVersion = "1.1"
    /// Object-lane manifests are built at this version; inline binary posts stay at `binaryVersion`.
    public static let objectVersion = "1.2"
    /// Sender-preferred list for capability negotiation (`GET`); see PUSH_PROTOCOL.md.
    public static let capabilitiesAcceptVersions = "1.2,1.1,1.0"
    public static let forbiddenRemoteControlMembers: Set<String> = [
        "command", "commands", "endpoint", "url", "cadence", "schema", "fields",
    ]

    private static let uuidPlaceholder = "00000000-0000-0000-0000-000000000000"

    private static let appendRegistry: [String: (keys: [String], data: [String])] = [
        "hrSample": (["ts"], ["bpm"]),
        "rrInterval": (["ts", "rrMs", "seq"], ["ord", "srcChannel", "tsSuspect"]),
        "rrPacketProvenance": (["packetId"], ["ts", "sensorTs", "recordIndex", "rawHex", "srcChannel", "schemaVersion", "decoderVersion", "clockVersion", "timestampPrecisionSeconds", "clockOffsetSeconds", "declaredCount"]),
        "standardHRReceipt": (["receiptId"], ["ts", "sessionId", "notificationOrdinal", "receivedUnixMs", "receivedMonotonicNs", "rawHex", "schemaVersion", "clockVersion"]),
        "event": (["ts", "kind"], ["payloadJSON"]),
        "battery": (["ts"], ["soc", "mv", "charging"]),
        "spo2Sample": (["ts"], ["red", "ir"]),
        "skinTempSample": (["ts"], ["raw", "aux1Raw", "aux2Raw"]),
        "respSample": (["ts"], ["raw"]),
        "gravitySample": (["ts"], ["x", "y", "z", "dynAccel"]),
        "dailyMetric": (
            ["day"],
            [
                "totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances",
                "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct",
                "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir",
            ]
        ),
        "sleepSession": (
            ["startTs"],
            [
                "endTs", "efficiency", "restingHr", "avgHrv", "stagesJSON", "userEdited",
                "startTsAdjusted", "motionJSON", "sleepStateJSON", "stagingSparse",
            ]
        ),
        "workout": (
            ["startTs", "sport"],
            [
                "endTs", "source", "durationS", "energyKcal", "avgHr", "maxHr", "strain",
                "distanceM", "zonesJSON", "notes", "routePolyline", "steps",
            ]
        ),
        "journal": (["day", "question"], ["answeredYes", "notes", "numericValue"]),
    ]

    public static func appendBatch(
        table: PushAppendTable,
        sourceId: String,
        deviceId: String,
        startCursor: PushCursor?,
        records: [PushAppendRecord]
    ) throws -> PushBatch {
        try validateUUID(sourceId, name: "sourceId")
        guard !records.isEmpty else { throw PushProtocolException("append batch must contain a record") }
        guard records.count == 1 || zip(records, records.dropFirst()).allSatisfy({ $0.0.rowId < $0.1.rowId }) else {
            throw PushProtocolException("append records must be strictly ordered by rowid")
        }
        for record in records { try validateRecord(table: table, key: record.key, data: record.data) }

        let candidates = Array(records.prefix(PushProtocolLimits.maxRecords))
        var selectedRows: [PushAppendRecord] = []
        var selectedLines: [Data] = []
        var rowBytes = 0

        for candidate in candidates {
            let encodedRow = try encodeRecordLine(table: table, record: candidate)
            let end = try cursorFor(table: table, deviceId: deviceId, record: candidate)
            let candidateCount = selectedRows.count + 1
            let headerSize = try appendHeader(
                sourceId: sourceId, table: table, deviceId: deviceId,
                start: startCursor, end: end, count: candidateCount, batchId: uuidPlaceholder
            ).count
            if headerSize + rowBytes + encodedRow.count > PushProtocolLimits.maxBodyBytes { break }
            selectedRows.append(candidate)
            selectedLines.append(encodedRow)
            rowBytes += encodedRow.count
        }

        guard !selectedRows.isEmpty else {
            throw PushProtocolException("first append record exceeds the 4 MiB decoded batch limit")
        }

        let endCursor = try cursorFor(table: table, deviceId: deviceId, record: selectedRows.last!)
        let identity = appendIdentity(
            sourceId: sourceId, table: table, deviceId: deviceId,
            start: startCursor, end: endCursor, count: selectedRows.count
        )
        let batchId = stableUuid(header: identity, lines: selectedLines)
        let header = try appendHeader(
            sourceId: sourceId, table: table, deviceId: deviceId,
            start: startCursor, end: endCursor, count: selectedRows.count, batchId: batchId
        )
        let body = concatenate(header: header, lines: selectedLines)
        precondition(body.count <= PushProtocolLimits.maxBodyBytes)
        return PushBatch(
            protocolVersion: [.rrPacketProvenance, .standardHRReceipt].contains(table) ? "1.1" : version,
            batchId: batchId,
            sourceId: sourceId,
            table: table,
            deviceId: deviceId,
            mode: "append",
            startCursor: startCursor,
            endCursor: endCursor,
            recordCount: selectedRows.count,
            window: nil,
            body: body
        )
    }

    /// Builds every bounded part of one authoritative replacement. Empty snapshots produce one part.
    public static func mutableBatches(
        table: PushMutableTable,
        sourceId: String,
        deviceId: String,
        window: PushWindow,
        records: [PushMutableRecord]
    ) throws -> [PushBatch] {
        try validateUUID(sourceId, name: "sourceId")
        for record in records { try validateRecord(table: table, key: record.key, data: record.data) }
        let keyColumns = appendRegistry[table.wireName]!.keys
        let keyStrings = records.map { orderedObjectJson(orderedFields(keyColumns, values: $0.key)) }
        if Set(keyStrings).count != keyStrings.count {
            throw PushProtocolException("replace_window contains a duplicate key")
        }
        let lines = try records.map { try encodeMutableRecordLine(table: table, record: $0) }
        let replacementIdentity: [String: PushJSONValue] = [
            "deviceId": .string(deviceId),
            "delivery": .string("replace_window"),
            "protocolVersion": .string(version),
            "sourceId": .string(sourceId),
            "stream": .string(table.wireName),
            "window": .map(try selectorBounds(table: table, window: window)),
        ]
        let replacementId = stableUuid(header: replacementIdentity, lines: lines)

        var chunks: [[Data]] = []
        var current: [Data] = []
        var currentBytes = 0
        for line in lines {
            let nextCount = current.count + 1
            let conservativeHeader = try mutableHeader(
                sourceId: sourceId, table: table, deviceId: deviceId, window: window,
                replacementId: replacementId, part: Int.max, parts: Int.max, count: nextCount,
                batchId: uuidPlaceholder
            )
            if nextCount > PushProtocolLimits.maxRecords
                || conservativeHeader.count + currentBytes + line.count > PushProtocolLimits.maxBodyBytes {
                if current.isEmpty {
                    throw PushProtocolException("first replace_window record exceeds the 4 MiB decoded batch limit")
                }
                chunks.append(current)
                current = []
                currentBytes = 0
            }
            let oneHeader = try mutableHeader(
                sourceId: sourceId, table: table, deviceId: deviceId, window: window,
                replacementId: replacementId, part: Int.max, parts: Int.max, count: 1,
                batchId: uuidPlaceholder
            )
            if oneHeader.count + line.count > PushProtocolLimits.maxBodyBytes {
                throw PushProtocolException("replace_window record exceeds the 4 MiB decoded batch limit")
            }
            current.append(line)
            currentBytes += line.count
        }
        if !current.isEmpty || chunks.isEmpty { chunks.append(current) }

        let parts = chunks.count
        return try chunks.enumerated().map { index, partLines in
            let part = index + 1
            let identity = mutableIdentity(
                sourceId: sourceId, table: table, deviceId: deviceId, window: window,
                replacementId: replacementId, part: part, parts: parts, count: partLines.count
            )
            let batchId = stableUuid(header: identity, lines: partLines)
            let header = try mutableHeader(
                sourceId: sourceId, table: table, deviceId: deviceId, window: window,
                replacementId: replacementId, part: part, parts: parts, count: partLines.count,
                batchId: batchId
            )
            let body = concatenate(header: header, lines: partLines)
            precondition(partLines.count <= PushProtocolLimits.maxRecords && body.count <= PushProtocolLimits.maxBodyBytes)
            return PushBatch(
                protocolVersion: version,
                batchId: batchId,
                sourceId: sourceId,
                table: table,
                deviceId: deviceId,
                mode: "replace_window",
                startCursor: nil,
                endCursor: nil,
                recordCount: partLines.count,
                window: window,
                replacementId: replacementId,
                part: part,
                parts: parts,
                body: body
            )
        }
    }

    public static func mutableBatch(
        table: PushMutableTable,
        sourceId: String,
        deviceId: String,
        window: PushWindow,
        records: [PushMutableRecord]
    ) throws -> PushBatch {
        let batches = try mutableBatches(table: table, sourceId: sourceId, deviceId: deviceId, window: window, records: records)
        guard batches.count == 1, let batch = batches.first else {
            throw PushProtocolException("replace_window requires multiple parts")
        }
        return batch
    }

    public static func mutableRecordEncodedSize(table: PushMutableTable, record: PushMutableRecord) throws -> Int {
        try validateRecord(table: table, key: record.key, data: record.data)
        return try encodeMutableRecordLine(table: table, record: record).count
    }

    /// Stable local content identity. Progress metadata only; never sent to the receiver.
    public static func mutableSnapshotHash(table: PushMutableTable, records: [PushMutableRecord]) throws -> String {
        let lines = try records.map { record -> Data in
            try validateRecord(table: table, key: record.key, data: record.data)
            return try encodeMutableRecordLine(table: table, record: record)
        }.sorted { compareBytes($0, $1) < 0 }
        var hasher = SHA256()
        hasher.update(data: Data("noop-push-day-hash\n\(version)\n\(table.wireName)\n".utf8))
        for line in lines { hasher.update(data: line) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func keyFingerprint(table: PushAppendTable, deviceId: String, key: [String: PushJSONValue]) throws -> String {
        try validateRecordKeys(table: table, key: key)
        let spec = appendRegistry[table.wireName]!
        let payload = "\(table.wireName)\n\(deviceId)\n\(orderedObjectJson(orderedFields(spec.keys, values: key)))"
        return sha256Hex(Data(payload.utf8))
    }

    public static func binaryKeyFingerprint(table: PushBinaryTable, deviceId: String, row: PushBinaryRow) throws -> String {
        let payload: String = switch (table, row) {
        case (.ppgWaveformSample, .ppgWaveform(let record)):
            "ppgWaveformSample\n\(deviceId)\n\(record.ts)\n\(record.burstIndex.map(String.init) ?? "")"
                + (record.recordIndex.map { "\nrecordIndex=\($0)" } ?? "")
        case (.v18AuxSample, .v18Aux(let record)):
            "v18AuxSample\n\(deviceId)\n\(record.ts)"
        case (.rawBatch, .rawBatch(let record)):
            "rawBatch\n\(deviceId)\n\(record.batchId)"
        case (.rawImuSession, .rawImuSession(let record)):
            "rawImuSession\n\(deviceId)\n\(record.ts)"
        default:
            throw PushProtocolException("binary row kind mismatch")
        }
        return sha256Hex(Data(payload.utf8))
    }

    public static func binaryObjectBatch(
        table: PushBinaryTable,
        sourceId: String,
        deviceId: String,
        startCursor: PushCursor?,
        rows: [PushBinaryRow],
        protocolVersion: String = binaryVersion,
        decodedLimit: Int = PushProtocolLimits.maxBodyBytes
    ) throws -> PushBinaryBatch {
        try validateUUID(sourceId, name: "sourceId")
        guard !rows.isEmpty else { throw PushProtocolException("binary object must contain a row") }

        let selected: [PushBinaryRow]
        switch table {
        case .rawBatch:
            guard rows.count == 1 else { throw PushProtocolException("rawBatch upload must contain exactly one row") }
            selected = rows
        case .ppgWaveformSample, .v18AuxSample, .rawImuSession:
            selected = try selectBinaryRows(table: table, rows: rows, decodedLimit: decodedLimit)
        }

        let decoded = try PushBinaryCodec.pack(table: table, rows: selected)
        guard decoded.count <= decodedLimit else {
            throw PushProtocolException("binary object exceeds the decoded limit")
        }
        let contentSha256 = PushBinaryCodec.sha256Hex(decoded)
        let contentEncoding = table.contentEncoding
        let payload = protocolVersion == objectVersion
            ? try PushBinaryCompression.compressObject(decoded, encoding: contentEncoding)
            : try PushBinaryCompression.compress(decoded, encoding: contentEncoding)
        let (startTs, endTs, sampleCount) = try binaryBounds(table: table, rows: selected)
        let endCursor = try binaryEndCursor(table: table, deviceId: deviceId, rows: selected)
        let identity: [String: PushJSONValue] = [
            "contentSha256": .string(contentSha256),
            "deviceId": .string(deviceId),
            "protocolVersion": .string(protocolVersion),
            "sampleCount": .int(Int64(sampleCount)),
            "sourceId": .string(sourceId),
            "startTs": .int(startTs),
            "endTs": .int(endTs),
            "stream": .string(table.wireName),
            "type": .string("binaryObject"),
        ]
        let batchId = stableUuid(header: identity, lines: [decoded])
        let objectId = stableUuid(
            header: identity.merging(["batchId": .string(batchId)]) { $1 },
            lines: [decoded]
        )
        var manifest = identity
        manifest["batchId"] = .string(batchId)
        manifest["objectId"] = .string(objectId)
        manifest["uncompressedBytes"] = .int(Int64(decoded.count))
        manifest["contentEncoding"] = .string(contentEncoding)
        let manifestJSON = Data(try canonicalJsonMap(manifest).utf8)
        return PushBinaryBatch(
            protocolVersion: protocolVersion,
            batchId: batchId,
            sourceId: sourceId,
            table: table,
            deviceId: deviceId,
            objectId: objectId,
            startTs: startTs,
            endTs: endTs,
            sampleCount: sampleCount,
            uncompressedBytes: decoded.count,
            contentSha256: contentSha256,
            contentEncoding: contentEncoding,
            endCursor: endCursor,
            manifestJSON: manifestJSON,
            payload: payload
        )
    }

    /// Fresh random object id for the `object_id_conflict` escape: the burned id can never be
    /// re-used, and a deterministic re-mint of the same identity would collide again.
    public static func freshObjectId() -> String {
        UUID().uuidString.lowercased()
    }

    private static func selectBinaryRows(table: PushBinaryTable, rows: [PushBinaryRow], decodedLimit: Int) throws -> [PushBinaryRow] {
        var selected: [PushBinaryRow] = []
        let ppgIdentity = rows.contains { if case .ppgWaveform(let r) = $0 { return r.recordIndex != nil }; return false }
        var decodedBytes = PushBinaryCodec.packedHeaderSize(for: table)
        var windowStartTs: Int64? = nil
        for row in rows.prefix(PushProtocolLimits.maxRecords) {
            if table == .rawImuSession {
                guard case .rawImuSession(let record) = row else {
                    throw PushProtocolException("binary row kind mismatch")
                }
                if let start = windowStartTs, record.ts - start >= PushProtocolLimits.maxImuObjectWindowSeconds {
                    break
                }
            }
            let rowSize = try PushBinaryCodec.packedRowSize(row, ppgIdentity: ppgIdentity)
            if decodedBytes + rowSize > decodedLimit { break }
            selected.append(row)
            decodedBytes += rowSize
            if table == .rawImuSession, windowStartTs == nil, case .rawImuSession(let record) = row {
                windowStartTs = record.ts
            }
        }
        guard !selected.isEmpty else {
            throw PushProtocolException("first binary row exceeds the decoded batch limit")
        }
        return selected
    }

    private static func binaryBounds(table: PushBinaryTable, rows: [PushBinaryRow]) throws -> (Int64, Int64, Int) {
        switch table {
        case .rawBatch:
            guard case .rawBatch(let record) = rows[0] else {
                throw PushProtocolException("binary row kind mismatch")
            }
            guard record.endTs >= record.startTs else {
                throw PushProtocolException("rawBatch capture bounds are reversed")
            }
            let (endExclusive, overflow) = record.endTs.addingReportingOverflow(1)
            guard !overflow else { throw PushProtocolException("rawBatch capture end overflows") }
            // Stored capture bounds include the last captured second. Only manifest indexing
            // is half-open; retain the original bounds and clocks inside the packed evidence.
            // This does not claim continuous sensor coverage within the capture interval.
            return (record.startTs, endExclusive, Int(record.frameCount))
        case .ppgWaveformSample, .v18AuxSample, .rawImuSession:
            let timestamps: [Int64] = try rows.map { row in
                switch row {
                case .ppgWaveform(let record): return record.ts
                case .v18Aux(let record): return record.ts
                case .rawImuSession(let record): return record.ts
                default: throw PushProtocolException("binary row kind mismatch")
                }
            }
            guard let minTs = timestamps.min(), let maxTs = timestamps.max() else {
                throw PushProtocolException("binary object has no timestamps")
            }
            return (minTs, maxTs + 1, rows.count)
        }
    }

    private static func binaryEndCursor(
        table: PushBinaryTable,
        deviceId: String,
        rows: [PushBinaryRow]
    ) throws -> PushCursor? {
        switch table {
        case .rawBatch:
            return nil
        case .ppgWaveformSample, .v18AuxSample, .rawImuSession:
            guard let last = rows.last else { return nil }
            let rowId: Int64
            switch last {
            case .ppgWaveform(let record): rowId = record.rowId
            case .v18Aux(let record): rowId = record.rowId
            case .rawImuSession(let record): rowId = record.rowId
            default: throw PushProtocolException("binary row kind mismatch")
            }
            return PushCursor(
                rowId: rowId,
                naturalKeyFingerprint: try binaryKeyFingerprint(table: table, deviceId: deviceId, row: last)
            )
        }
    }

    public static func canonicalJson(_ value: PushJSONValue?) throws -> String {
        var out = ""
        try appendCanonical(value, to: &out, sortMaps: true)
        return out
    }

    public static func canonicalJsonMap(_ value: [String: PushJSONValue]) throws -> String {
        var out = ""
        try appendCanonical(.map(value), to: &out, sortMaps: true)
        return out
    }

    // MARK: - Private encoding

    private static func orderedObjectJson(_ value: [String: PushJSONValue]) -> String {
        var out = ""
        do {
            try appendCanonical(.map(value), to: &out, sortMaps: false)
        } catch {
            return "{}"
        }
        return out
    }

    private static func appendCanonical(_ value: PushJSONValue?, to out: inout String, sortMaps: Bool) throws {
        switch value {
        case nil, .null:
            out.append("null")
        case .string(let s):
            appendQuoted(s, to: &out)
        case .bool(let b):
            out.append(b ? "true" : "false")
        case .int(let i):
            out.append(String(i))
        case .double(let d):
            guard d.isFinite else { throw PushProtocolException("non-finite number is not valid JSON") }
            out.append(String(d))
        case .map(let map):
            let entries = sortMaps
                ? map.sorted { $0.key < $1.key }
                : map.map { ($0.key, $0.value) }
            out.append("{")
            for (index, entry) in entries.enumerated() {
                if index > 0 { out.append(",") }
                appendQuoted(entry.0, to: &out)
                out.append(":")
                try appendCanonical(entry.1, to: &out, sortMaps: sortMaps)
            }
            out.append("}")
        case .array(let items):
            out.append("[")
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(",") }
                try appendCanonical(item, to: &out, sortMaps: sortMaps)
            }
            out.append("]")
        }
    }

    private static func appendQuoted(_ value: String, to out: inout String) {
        out.append("\"")
        for ch in value {
            switch ch {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\u{8}": out.append("\\b")
            case "\u{C}": out.append("\\f")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if ch.unicodeScalars.first!.value < 0x20 {
                    out.append(String(format: "\\u%04x", ch.unicodeScalars.first!.value))
                } else {
                    out.append(ch)
                }
            }
        }
        out.append("\"")
    }

    private static func encodeRecordLine(table: PushAppendTable, record: PushAppendRecord) throws -> Data {
        let spec = appendRegistry[table.wireName]!
        let line: [String: PushJSONValue] = [
            "type": .string("record"),
            "key": .map(orderedFields(spec.keys, values: record.key)),
            "data": .map(orderedFields(spec.data, values: record.data)),
        ]
        return try encodeLine(line)
    }

    private static func encodeMutableRecordLine(table: PushMutableTable, record: PushMutableRecord) throws -> Data {
        let spec = appendRegistry[table.wireName]!
        let line: [String: PushJSONValue] = [
            "type": .string("record"),
            "key": .map(orderedFields(spec.keys, values: record.key)),
            "data": .map(orderedFields(spec.data, values: record.data)),
        ]
        return try encodeLine(line)
    }

    private static func orderedFields(_ columns: [String], values: [String: PushJSONValue]) -> [String: PushJSONValue] {
        Dictionary(uniqueKeysWithValues: columns.compactMap { column in
            values[column].map { (column, $0) }
        })
    }

    private static func encodeLine(_ value: [String: PushJSONValue]) throws -> Data {
        var json = ""
        try appendCanonical(.map(value), to: &json, sortMaps: true)
        json.append("\n")
        return Data(json.utf8)
    }

    private static func appendIdentity(
        sourceId: String, table: PushAppendTable, deviceId: String,
        start: PushCursor?, end: PushCursor, count: Int
    ) -> [String: PushJSONValue] {
        [
            "delivery": .string("append"),
            "deviceId": .string(deviceId),
            "endCursor": .map(cursorJson(end)),
            "protocolVersion": .string([.rrPacketProvenance, .standardHRReceipt].contains(table) ? "1.1" : version),
            "recordCount": .int(Int64(count)),
            "sourceId": .string(sourceId),
            "startCursor": start.map { .map(cursorJson($0)) } ?? .null,
            "stream": .string(table.wireName),
            "type": .string("batch"),
        ]
    }

    private static func appendHeader(
        sourceId: String, table: PushAppendTable, deviceId: String,
        start: PushCursor?, end: PushCursor, count: Int, batchId: String
    ) throws -> Data {
        var header = appendIdentity(sourceId: sourceId, table: table, deviceId: deviceId, start: start, end: end, count: count)
        header["batchId"] = .string(batchId)
        return try encodeLine(header)
    }

    private static func mutableIdentity(
        sourceId: String, table: PushMutableTable, deviceId: String, window: PushWindow,
        replacementId: String, part: Int, parts: Int, count: Int
    ) -> [String: PushJSONValue] {
        var windowBounds = (try? selectorBounds(table: table, window: window)) ?? [:]
        windowBounds["part"] = .int(Int64(part))
        windowBounds["parts"] = .int(Int64(parts))
        windowBounds["replacementId"] = .string(replacementId)
        return [
            "delivery": .string("replace_window"),
            "deviceId": .string(deviceId),
            "endCursor": .null,
            "protocolVersion": .string(version),
            "recordCount": .int(Int64(count)),
            "sourceId": .string(sourceId),
            "startCursor": .null,
            "stream": .string(table.wireName),
            "type": .string("batch"),
            "window": .map(windowBounds),
        ]
    }

    private static func mutableHeader(
        sourceId: String, table: PushMutableTable, deviceId: String, window: PushWindow,
        replacementId: String, part: Int, parts: Int, count: Int, batchId: String
    ) throws -> Data {
        var header = mutableIdentity(
            sourceId: sourceId, table: table, deviceId: deviceId, window: window,
            replacementId: replacementId, part: part, parts: parts, count: count
        )
        header["batchId"] = .string(batchId)
        return try encodeLine(header)
    }

    private static func selectorBounds(table: PushMutableTable, window: PushWindow) throws -> [String: PushJSONValue] {
        switch table {
        case .dailyMetric, .journal:
            guard let endDay = dayAfter(window.toDay) else {
                throw PushProtocolException("mutable day window is invalid")
            }
            return [
                "endExclusive": .string(endDay),
                "selector": .string("day"),
                "startInclusive": .string(window.fromDay),
            ]
        case .sleepSession, .workout:
            return [
                "endExclusive": .int(window.endTsExclusive),
                "selector": .string("startTs"),
                "startInclusive": .int(window.startTsInclusive),
            ]
        }
    }

    private static func dayAfter(_ day: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: day) else { return nil }
        guard let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: date) else { return nil }
        return formatter.string(from: next)
    }

    private static func compareBytes(_ left: Data, _ right: Data) -> Int {
        let common = min(left.count, right.count)
        for index in 0..<common {
            let difference = Int(left[index]) - Int(right[index])
            if difference != 0 { return difference }
        }
        return left.count - right.count
    }

    private static func cursorFor(table: PushAppendTable, deviceId: String, record: PushAppendRecord) throws -> PushCursor {
        PushCursor(rowId: record.rowId, naturalKeyFingerprint: try keyFingerprint(table: table, deviceId: deviceId, key: record.key))
    }

    private static func cursorJson(_ cursor: PushCursor) -> [String: PushJSONValue] {
        ["keySha256": .string(cursor.naturalKeyFingerprint), "rowId": .int(cursor.rowId)]
    }

    private static func stableUuid(header: [String: PushJSONValue], lines: [Data]) -> String {
        var hasher = SHA256()
        if let json = try? canonicalJsonMap(header) {
            hasher.update(data: Data(json.utf8))
        }
        hasher.update(data: Data([0x0A]))
        for line in lines { hasher.update(data: line) }
        var bytes = Array(hasher.finalize())
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid).uuidString.lowercased()
    }

    private static func concatenate(header: Data, lines: [Data]) -> Data {
        var out = Data(capacity: header.count + lines.reduce(0) { $0 + $1.count })
        out.append(header)
        for line in lines { out.append(line) }
        return out
    }

    private static func validateRecord(table: any PushTable, key: [String: PushJSONValue], data: [String: PushJSONValue]) throws {
        guard let spec = appendRegistry[table.wireName] else {
            throw PushProtocolException("\(table.wireName) is not in append registry")
        }
        guard spec.keys.allSatisfy({ key[$0] != nil }), key.count == spec.keys.count else {
            throw PushProtocolException("\(table.wireName) key does not match registry")
        }
        guard Set(data.keys) == Set(spec.data), data.count == spec.data.count else {
            throw PushProtocolException("\(table.wireName) data does not match registry")
        }
        if key.keys.contains("deviceId") || data.keys.contains("deviceId") || data.keys.contains("synced") {
            throw PushProtocolException("batch-scoped or local-only column in record")
        }
    }

    private static func validateRecordKeys(table: PushAppendTable, key: [String: PushJSONValue]) throws {
        guard let spec = appendRegistry[table.wireName],
              spec.keys.allSatisfy({ key[$0] != nil }),
              key.count == spec.keys.count else {
            throw PushProtocolException("\(table.wireName) key does not match registry")
        }
    }

    private static func validateUUID(_ value: String, name: String) throws {
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
            throw PushProtocolException("\(name) must be a lowercase canonical UUID")
        }
    }

    private static func sha256Hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
