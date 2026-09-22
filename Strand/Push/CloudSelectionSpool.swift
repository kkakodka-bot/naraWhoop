import Foundation
import CryptoKit
import NoopPush

/// Compact selection metadata contains no sensor bytes. Loading a lane never loads other lanes.
struct CloudSelectionIndex: Codable, Sendable {
    let version: Int
    let id: String
    let owner: AccountScope
    let sourceID: String
    let endpoint: String
    let receiverStateID: String
    let laneID: String
    let commit: PushSourceCommit
    let objectID: String?
    let reservation: CloudPreparedQuota.Reservation
    let segment: String
    let segmentBytes: Int
    /// Present only for an unconverted legacy JSON selection. It is never spool authority.
    let legacyEncodedBytes: Int?
    var isLegacy: Bool { legacyEncodedBytes != nil }

    init(_ value: CloudPushPreparedSelection, reservation: CloudPreparedQuota.Reservation, segment: String, bytes: Int) {
        version = 1; id = value.id; owner = value.owner; sourceID = value.sourceID
        endpoint = value.endpoint; receiverStateID = value.receiverStateID; laneID = value.laneID
        commit = value.commit; objectID = value.selection.objectManifest?.objectId
        self.reservation = reservation; self.segment = segment; segmentBytes = bytes
        legacyEncodedBytes = nil
    }

    /// Decode scalar membership only: no base64 payload decoding, recompression or canonical hash.
    /// Full validation still precedes the first use/conversion of the saved selection.
    init(legacy bytes: Data, owner expected: AccountScope) throws {
        guard !bytes.isEmpty, bytes.count <= PushPreparedSelection.maximumEncodedBytes else { throw CloudUploadError.corruptJournal }
        let header = try JSONDecoder().decode(LegacyHeader.self, from: bytes)
        guard header.version == CloudPushPreparedSelection.formatVersion,
              header.owner == expected, header.selection.version == PushPreparedSelection.formatVersion,
              PushProtocol.capabilitiesAcceptVersions.split(separator: ",").contains(Substring(header.progressVersion)) else {
            throw CloudUploadError.corruptJournal
        }
        version = 1; id = header.id; owner = header.owner; endpoint = header.endpoint
        let commit = header.selection.commit
        receiverStateID = header.receiverStateID; self.commit = commit
        let jobs: Int
        if let binary = header.selection.binary {
            let manifest = binary.manifest
            guard header.selection.inline.isEmpty, commit.kind == .binary,
                  commit.batchIDs == [manifest.batchId], commit.deviceID == manifest.deviceId,
                  commit.table == manifest.stream, commit.cursor == binary.endCursor, commit.window == nil,
                  Self.validUUID(manifest.objectId), Self.validUUID(manifest.sourceId) else { throw CloudUploadError.corruptJournal }
            sourceID = manifest.sourceId; objectID = manifest.objectId; jobs = 2
        } else {
            let parts = header.selection.inline
            guard let first = parts.first, parts.count <= PushPreparedSelection.maximumParts,
                  commit.kind != .binary, commit.rawBatchIDs.isEmpty,
                  parts.map(\.batchID) == commit.batchIDs,
                  parts.allSatisfy({ $0.sourceID == first.sourceID && $0.deviceID == commit.deviceID
                    && $0.table == commit.table && $0.protocolVersion == first.protocolVersion }),
                  Self.validUUID(first.sourceID) else { throw CloudUploadError.corruptJournal }
            if commit.kind == .append {
                guard parts.count == 1, first.mode == "append", commit.cursor != nil,
                      commit.cursor == first.endCursor, commit.window == nil else { throw CloudUploadError.corruptJournal }
            } else {
                guard commit.cursor == nil, commit.window != nil, parts.allSatisfy({ $0.mode == "replace_window" }) else { throw CloudUploadError.corruptJournal }
            }
            sourceID = first.sourceID; objectID = nil; jobs = parts.count * 2
        }
        let admission = try AccountPushAdmission(context: .init(scope: owner, generation: header.capturedGeneration),
            captureScope: owner, sourceID: sourceID, isCurrent: { _ in true })
        guard header.progressNamespace == admission.namespace(endpoint: endpoint,
            protocolVersion: header.progressVersion, receiverStateID: receiverStateID) else { throw CloudUploadError.corruptJournal }
        laneID = AccountScope.digest([owner.namespace, sourceID, endpoint, receiverStateID,
            commit.kind.rawValue, commit.table, commit.deviceID].joined(separator: "\u{0}"))
        // The encoded length bounds every embedded body. Reserve conservatively until one admitted
        // conversion can compute the exact existing allocation; never reject already-durable debt.
        reservation = .init(bodyBytes: bytes.count * 4, selectionBytes: bytes.count * 2,
            jobSlots: jobs, completionBytes: jobs * CloudPreparedQuota.jobMetadataBytes + CloudPreparedQuota.groupCompletionBytes)
        segment = ""; segmentBytes = 0; legacyEncodedBytes = bytes.count
        try validate(owner: expected)
    }

    private struct LegacyHeader: Decodable {
        let version: Int
        let id: String
        let owner: AccountScope
        let capturedGeneration: UUID
        let endpoint, receiverStateID, progressVersion, progressNamespace: String
        let selection: LegacySelection
    }
    private struct LegacySelection: Decodable {
        let version: Int
        let commit: PushSourceCommit
        let inline: [LegacyInline]
        let binary: LegacyBinary?
    }
    private struct LegacyInline: Decodable {
        let protocolVersion, batchID, sourceID, table, deviceID, mode: String
        let endCursor: PushCursor?
    }
    private struct LegacyBinary: Decodable {
        let manifest: PushObjectManifest
        let endCursor: PushCursor?
    }
    func matches(owner: AccountScope, sourceID: String, endpoint: String, receiverStateID: String) -> Bool {
        self.owner == owner && self.sourceID == sourceID && self.endpoint == endpoint && self.receiverStateID == receiverStateID
    }
    func matches(_ value: CloudPushPreparedSelection) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard id == value.id && laneID == value.laneID && owner == value.owner && sourceID == value.sourceID
            && endpoint == value.endpoint && receiverStateID == value.receiverStateID
            && objectID == value.selection.objectManifest?.objectId else { return false }
        if !isLegacy {
            guard reservation == (try CloudPreparedQuota(maximumBytes: Int.max).reservation(for: value)) else { return false }
        }
        return try encoder.encode(commit) == encoder.encode(value.commit)
    }
    func jobID(batchID: String, representation: String, objectID: String = "") -> String {
        AccountScope.digest(["prepared-job-v2", id, batchID, representation, objectID].joined(separator: "\u{0}"))
    }
    func jobIDs(_ state: CloudPreparedContinuation) -> [String] {
        if objectID != nil { return state.objectIDs.map { jobID(batchID: commit.batchIDs[0], representation: "object", objectID: $0) } }
        return commit.batchIDs.flatMap { batch in ["gzip", "identity"].map { jobID(batchID: batch, representation: $0) } }
    }
    func validate(owner: AccountScope) throws {
        guard version == 1, self.owner == owner, Self.validHash(id), Self.validHash(laneID),
              endpoint == owner.projectURL + "/functions/v1/push", !sourceID.isEmpty, !receiverStateID.isEmpty,
              !commit.batchIDs.isEmpty, commit.batchIDs.count <= PushPreparedSelection.maximumParts,
              Set(commit.batchIDs).count == commit.batchIDs.count, commit.batchIDs.allSatisfy(Self.validUUID),
              !commit.deviceID.isEmpty, commit.deviceID.utf8.count <= 1024,
              segmentBytes >= 0, segmentBytes <= PushPreparedSelection.maximumEncodedBytes,
              reservation.total > 0, reservation.bodyBytes >= 0, reservation.selectionBytes >= 0,
              reservation.completionBytes >= 0, reservation.jobSlots > 0, reservation.jobSlots <= 256 else { throw CloudUploadError.corruptJournal }
        if let legacyEncodedBytes {
            guard legacyEncodedBytes > 0, legacyEncodedBytes <= PushPreparedSelection.maximumEncodedBytes,
                  segment.isEmpty, segmentBytes == 0 else { throw CloudUploadError.corruptJournal }
        } else {
            guard Self.validHash(String(segment.dropLast(8))), segment.hasSuffix(".segment") else { throw CloudUploadError.corruptJournal }
        }
    }
    private static func validUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString.lowercased() == value }
    static func validHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
}

extension CloudPreparedContinuation {
    func validate(_ index: CloudSelectionIndex) throws {
        guard version == 2, selectionID == index.id, objectIDs.count <= 2, Set(objectIDs).count == objectIDs.count,
              objectIDs.allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }),
              conflictedObjectIDs.isSubset(of: Set(objectIDs)) else { throw CloudUploadError.corruptJournal }
        if let first = index.objectID {
            guard objectIDs.first == first, objectIDs.count < 2 || conflictedObjectIDs.contains(objectIDs[0]) else { throw CloudUploadError.corruptJournal }
        } else if !objectIDs.isEmpty || !conflictedObjectIDs.isEmpty { throw CloudUploadError.corruptJournal }
    }
}

/// Data fields are appended once to an immutable segment. JSON holds only bounded offset/digest refs,
/// avoiding raw/gzip/base64/JSON copies of each byte array. Decoding retains existing identity checks.
enum CloudSelectionSpool {
    struct Intent: Codable { let pending: String; let segment: String; let bytes: Int }
    struct Reference: Codable { let offset: Int; let count: Int; let sha256: String }
    enum PublicationPoint: CaseIterable { case segmentSynced, intentCommitted, renamed }
    struct Encoded { let manifest: Data; let segment: String; let bytes: Int; let pending: String }

    static func encode(_ value: CloudPushPreparedSelection, journal: CloudUploadJournal,
                       reservation: CloudPreparedQuota.Reservation,
                       checkpoint: (PublicationPoint) throws -> Void = { _ in }) throws -> Encoded {
        guard journal.permitsPreparation() else { throw CloudUploadError.retryScheduled }
        let pending = value.id + ".spoolpending"
        try recoverPublication(value.id, journal: journal)
        let url = journal.directory.appendingPathComponent(pending)
        // Account before creation. A killed writer leaves a conservative reservation, never free space.
        try journal.metadata.recordFile(pending, bytes: reservation.selectionBytes)
        try Data().write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var offset = 0, digest = SHA256()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        encoder.dataEncodingStrategy = .custom { data, encoder in
            guard journal.permitsPreparation() else { throw CloudUploadError.retryScheduled }
            guard data.count <= PushPreparedSelection.maximumEncodedBytes - offset else { throw CloudUploadError.storageFull }
            let reference = Reference(offset: offset, count: data.count, sha256: CloudUploadJournal.digest(data))
            try handle.write(contentsOf: data)
            digest.update(data: data); offset += data.count
            try reference.encode(to: encoder)
        }
        let manifest = try encoder.encode(value)
        guard manifest.count <= 16 * 1_048_576 else { throw CloudUploadError.storageFull }
        try handle.synchronize()
        try checkpoint(.segmentSynced)
        let name = digest.finalize().map { String(format: "%02x", $0) }.joined() + ".segment"
        // The future rename target is durable before the rename, closing the orphan-file window.
        try journal.metadata.transaction {
            try journal.metadata.put(value.id + ".spoolintent", data: JSONEncoder().encode(Intent(pending: pending, segment: name, bytes: offset)))
            try journal.metadata.recordFile(pending, bytes: offset)
        }
        try checkpoint(.intentCommitted)
        let destination = journal.directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) {
            try verifySegment(destination, expected: name, bytes: offset)
            try journal.unlinkFile(url)
        } else { try FileManager.default.moveItem(at: url, to: destination) }
        try journal.syncDirectory()
        try checkpoint(.renamed)
        return .init(manifest: manifest, segment: name, bytes: offset, pending: pending)
    }

    static func recoverPublications(journal: CloudUploadJournal) throws {
        let ids = Set(try journal.metadata.names(kind: "spoolintent").map { String($0.dropLast(12)) })
            .union(try journal.metadata.fileNames(suffix: ".spoolpending").map { String($0.dropLast(13)) })
        for id in ids { try recoverPublication(id, journal: journal) }
    }
    static func recoverPublication(_ id: String, journal: CloudUploadJournal) throws {
        guard CloudSelectionIndex.validHash(id) else { throw CloudUploadError.corruptJournal }
        let pending = id + ".spoolpending"
        if let bytes = try journal.metadata.read(id + ".spoolintent") {
            let intent = try JSONDecoder().decode(Intent.self, from: bytes)
            guard intent.pending == pending, intent.bytes >= 0,
                  intent.segment.hasSuffix(".segment"), CloudSelectionIndex.validHash(String(intent.segment.dropLast(8))),
                  !(try journal.metadata.contains(id + ".selection-index")) else { throw CloudUploadError.corruptJournal }
            // An intent without a published selection has never authorized a task/source deletion.
            // Other published selections may share the digest-keyed segment.
            var referenced = false
            for name in try journal.metadata.names(kind: "selection-index") {
                guard let bytes = try journal.metadata.read(name) else { throw CloudUploadError.corruptJournal }
                if try JSONDecoder().decode(CloudSelectionIndex.self, from: bytes).segment == intent.segment { referenced = true; break }
            }
            if !referenced { try journal.unlinkFile(journal.directory.appendingPathComponent(intent.segment)) }
            try journal.metadata.remove(id + ".spoolintent")
        }
        if try journal.metadata.fileBytes(pending) > 0 || FileManager.default.fileExists(atPath: journal.directory.appendingPathComponent(pending).path) {
            try journal.unlinkFile(journal.directory.appendingPathComponent(pending))
        }
    }

    static func decode(_ bytes: Data, index: CloudSelectionIndex, directory: URL) throws -> CloudPushPreparedSelection {
        guard !index.isLegacy else { throw CloudUploadError.corruptJournal }
        let path = directory.appendingPathComponent(index.segment)
        try verifySegment(path, expected: index.segment, bytes: index.segmentBytes)
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .custom { decoder in
            let reference = try Reference(from: decoder)
            guard reference.offset >= 0, reference.count >= 0,
                  reference.offset <= index.segmentBytes, reference.count <= index.segmentBytes - reference.offset else { throw CloudUploadError.corruptJournal }
            try handle.seek(toOffset: UInt64(reference.offset))
            let value = try handle.read(upToCount: reference.count) ?? Data()
            guard value.count == reference.count, CloudUploadJournal.digest(value) == reference.sha256 else { throw CloudUploadError.changedPayload }
            return value
        }
        let value = try decoder.decode(CloudPushPreparedSelection.self, from: bytes)
        guard try index.matches(value) else { throw CloudUploadError.changedPayload }
        return value
    }
    static func verifySegment(_ path: URL, expected: String, bytes: Int) throws {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var digest = SHA256(), total = 0
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            total += chunk.count
            guard total <= bytes else { throw CloudUploadError.changedPayload }
            digest.update(data: chunk)
        }
        let name = digest.finalize().map { String(format: "%02x", $0) }.joined() + ".segment"
        guard total == bytes, name == expected else { throw CloudUploadError.changedPayload }
    }
}
