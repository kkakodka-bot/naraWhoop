import Foundation
import NoopPush
import zlib

/// Immutable local selection. Runtime authorization is checked separately; capture generation never changes.
struct CloudPushPreparedSelection: Codable, Sendable {
    static let formatVersion = 2
    let version: Int
    let id: String
    let owner: AccountScope
    let capturedGeneration: UUID
    let endpoint: String
    let receiverStateID: String
    let progressVersion: String
    let progressNamespace: String
    let correlation: UUID
    let selection: PushPreparedSelection
    let inlineGzip: [Data]

    init(context: AccountSessionContext, endpoint: String, receiverStateID: String, progressVersion: String,
         selection: PushPreparedSelection, inlineGzip: [Data], correlation: UUID = UUID()) throws {
        version = Self.formatVersion; owner = context.scope; capturedGeneration = context.generation
        self.endpoint = endpoint; self.receiverStateID = receiverStateID; self.progressVersion = progressVersion
        self.selection = selection; self.inlineGzip = inlineGzip; self.correlation = correlation
        let admission = try AccountPushAdmission(context: context, captureScope: context.scope,
            sourceID: selection.sourceID, isCurrent: { _ in true })
        progressNamespace = admission.namespace(endpoint: endpoint, protocolVersion: progressVersion, receiverStateID: receiverStateID)
        id = try Self.identity(namespace: progressNamespace, selection: selection, gzip: inlineGzip)
        try validate()
    }

    /// Protocol version is deliberately excluded: an older replacement cannot be overtaken after negotiation changes.
    var laneID: String {
        AccountScope.digest([owner.namespace, selection.sourceID, endpoint, receiverStateID,
            selection.commit.kind.rawValue, selection.commit.table, selection.deviceID].joined(separator: "\u{0}"))
    }
    var sourceID: String { selection.sourceID }
    var commit: PushSourceCommit { selection.commit }
    var context: AccountSessionContext { .init(scope: owner, generation: capturedGeneration) }

    func matches(owner: AccountScope, sourceID: String, endpoint: String, receiverStateID: String) -> Bool {
        self.owner == owner && self.sourceID == sourceID && self.endpoint == endpoint && self.receiverStateID == receiverStateID
    }
    func jobID(batchID: String, representation: String, objectID: String = "") -> String {
        AccountScope.digest(["prepared-job-v2", id, batchID, representation, objectID].joined(separator: "\u{0}"))
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= PushPreparedSelection.maximumEncodedBytes else { throw CloudUploadError.storageFull }
        return data
    }
    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= PushPreparedSelection.maximumEncodedBytes else { throw CloudUploadError.corruptJournal }
        return try JSONDecoder().decode(Self.self, from: bytes)
    }
    private enum CodingKeys: String, CodingKey {
        case version, id, owner, capturedGeneration, endpoint, receiverStateID, progressVersion
        case progressNamespace, correlation, selection, inlineGzip
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.formatVersion else { throw CloudUploadError.corruptJournal }
        id = try c.decode(String.self, forKey: .id); owner = try c.decode(AccountScope.self, forKey: .owner)
        capturedGeneration = try c.decode(UUID.self, forKey: .capturedGeneration)
        endpoint = try c.decode(String.self, forKey: .endpoint)
        receiverStateID = try c.decode(String.self, forKey: .receiverStateID)
        progressVersion = try c.decode(String.self, forKey: .progressVersion)
        progressNamespace = try c.decode(String.self, forKey: .progressNamespace)
        correlation = try c.decode(UUID.self, forKey: .correlation)
        selection = try c.decode(PushPreparedSelection.self, forKey: .selection)
        inlineGzip = try c.decode([Data].self, forKey: .inlineGzip)
        try validate()
    }
    private func validate() throws {
        guard version == Self.formatVersion, endpoint == owner.projectURL + "/functions/v1/push",
              !receiverStateID.isEmpty, receiverStateID.utf8.count <= 256,
              PushProtocol.capabilitiesAcceptVersions.split(separator: ",").contains(Substring(progressVersion)) else {
            throw CloudUploadError.corruptJournal
        }
        let admission = try AccountPushAdmission(context: context, captureScope: owner, sourceID: sourceID, isCurrent: { _ in true })
        guard progressNamespace == admission.namespace(endpoint: endpoint, protocolVersion: progressVersion, receiverStateID: receiverStateID),
              id == (try Self.identity(namespace: progressNamespace, selection: selection, gzip: inlineGzip)) else { throw CloudUploadError.corruptJournal }
        let batches = try selection.restoredInlineBatches()
        guard inlineGzip.count == batches.count,
              inlineGzip.allSatisfy({ !$0.isEmpty && $0.count <= PushProtocolLimits.maxWireBodyBytes }) else { throw CloudUploadError.corruptJournal }
        for (batch, gzip) in zip(batches, inlineGzip) {
            guard try Self.decodedGzip(gzip, maximumBytes: batch.body.count) == batch.body else { throw CloudUploadError.changedPayload }
        }
    }
    private static func identity(namespace: String, selection: PushPreparedSelection, gzip: [Data]) throws -> String {
        AccountScope.digest((["prepared-selection-v2", namespace, PushDurabilityReceipt.sha256(try selection.encoded())]
            + gzip.map(PushDurabilityReceipt.sha256)).joined(separator: "\u{0}"))
    }
    private static func decodedGzip(_ data: Data, maximumBytes: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CloudUploadError.changedPayload }
        defer { inflateEnd(&stream) }
        var output = Data(), status = Z_OK
        try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            try buffer.withUnsafeMutableBufferPointer { chunk in
                repeat {
                    stream.next_out = chunk.baseAddress; stream.avail_out = uInt(chunk.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    let count = chunk.count - Int(stream.avail_out)
                    guard count <= maximumBytes - output.count else { throw CloudUploadError.changedPayload }
                    if count > 0 { output.append(chunk.baseAddress!, count: count) }
                } while status == Z_OK
            }
        }
        guard status == Z_STREAM_END, stream.avail_in == 0 else { throw CloudUploadError.changedPayload }
        return output
    }
}

/// Reserved completion bytes are not ordinary admission space. Physical write failures still retain debt.
struct CloudPreparedQuota: Sendable {
    static let jobMetadataBytes = 256 * 1024 // Two bounded atomic metadata copies per job.
    static let groupCompletionBytes = 512 * 1024
    var maximumBytes = 1_073_741_824
    var maximumGroups = 64
    var maximumJobs = 256

    struct Reservation: Equatable, Sendable {
        let bodyBytes: Int
        let selectionBytes: Int
        let jobSlots: Int
        let completionBytes: Int
        var total: Int {
            let (partial, firstOverflow) = bodyBytes.addingReportingOverflow(selectionBytes)
            let (total, secondOverflow) = partial.addingReportingOverflow(completionBytes)
            return firstOverflow || secondOverflow ? Int.max : total
        }
    }

    func reservation(for prepared: CloudPushPreparedSelection) throws -> Reservation {
        let encoded = try prepared.encoded()
        let inline = prepared.selection.inlineBodies
        let bodyBytes: Int
        let jobs: Int
        if let payload = prepared.selection.objectPayload {
            // The one permitted explicit object-ID conflict successor has space BEFORE the first intent.
            bodyBytes = payload.count * 2; jobs = 2
        } else {
            bodyBytes = inline.reduce(0) { $0 + $1.count } + prepared.inlineGzip.reduce(0) { $0 + $1.count }
            jobs = inline.count * 2
        }
        let completion = jobs * Self.jobMetadataBytes + Self.groupCompletionBytes
        let result = Reservation(bodyBytes: bodyBytes * 2, selectionBytes: encoded.count * 2, jobSlots: jobs, completionBytes: completion)
        guard jobs > 0, jobs <= maximumJobs, result.total <= maximumBytes else { throw CloudUploadError.storageFull }
        return result
    }

    func admit(_ reservation: Reservation, occupiedBytes: Int, reservedBytes: Int, groups: Int, jobs: Int) throws {
        guard maximumBytes > 0, maximumGroups > 0, maximumJobs > 0,
              reservation.bodyBytes >= 0, reservation.selectionBytes >= 0, reservation.completionBytes >= 0, reservation.jobSlots > 0,
              occupiedBytes >= 0, reservedBytes >= 0, groups >= 0, jobs >= 0,
              groups < maximumGroups, reservation.jobSlots <= maximumJobs,
              jobs <= maximumJobs - reservation.jobSlots,
              occupiedBytes <= maximumBytes, reservedBytes <= maximumBytes - occupiedBytes,
              reservation.total <= maximumBytes - occupiedBytes - reservedBytes else { throw CloudUploadError.storageFull }
    }
}

/// Small mutable continuation. The immutable selection is written first as a reservation;
/// published becomes true only after EVERY body and job descriptor has reached disk.
struct CloudPreparedContinuation: Codable, Sendable {
    var version = 2
    let selectionID: String
    var published = false
    var objectIDs: [String] = []
    var conflictedObjectIDs: Set<String> = []
    var sourceCommitted = false

    func validate(_ selection: CloudPushPreparedSelection) throws {
        guard version == 2, selectionID == selection.id, objectIDs.count <= 2,
              Set(objectIDs).count == objectIDs.count,
              objectIDs.allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }),
              conflictedObjectIDs.isSubset(of: Set(objectIDs)) else { throw CloudUploadError.corruptJournal }
        if let manifest = selection.selection.objectManifest {
            guard objectIDs.first == manifest.objectId,
                  objectIDs.count < 2 || conflictedObjectIDs.contains(objectIDs[0]) else { throw CloudUploadError.corruptJournal }
        } else if !objectIDs.isEmpty || !conflictedObjectIDs.isEmpty { throw CloudUploadError.corruptJournal }
    }
}

extension CloudPushPreparedSelection {
    func jobIDs(_ state: CloudPreparedContinuation) throws -> [String] {
        if let manifest = selection.objectManifest {
            return state.objectIDs.map { jobID(batchID: manifest.batchId, representation: "object", objectID: $0) }
        }
        return commit.batchIDs.flatMap { batch in ["gzip", "identity"].map { jobID(batchID: batch, representation: $0) } }
    }
}

enum CloudPushPreparedRecovery {
    /// Staged debt is finished first by the caller. Each operation reopens its ORIGINAL namespace;
    /// current negotiation and today's rolling window are irrelevant to its saved continuation.
    /// A blocked lane stays reserved while independent lanes may continue.
    static func recover(queue: CloudUploadQueue, context: AccountSessionContext, sourceID: String,
                        endpoint: String, receiverStateID: String, directory: URL,
                        coordinator: (CloudPushProgressStore, String) -> PushCoordinator) async throws -> Bool {
        let selections = try await queue.preparedSelections(sourceID: sourceID, endpoint: endpoint,
            receiverStateID: receiverStateID, captured: context)
        var blocked = false
        for selection in selections {
            do {
                try await queue.prepareSelection(selection, captured: context)
                let progress = try CloudPushProgressStore(namespace: selection.progressNamespace, directory: directory,
                    auxiliaryIdentityV2: selection.progressVersion == PushProtocol.auxiliaryIdentityVersion)
                let manifest = try await queue.resumeManifest(selectionID: selection.id, captured: context)
                let result = await coordinator(progress, selection.progressVersion).resumePrepared(selection.selection, manifestOverride: manifest)
                if case .accepted = result {} else { blocked = true }
            } catch CloudUploadError.staleOwner { throw CloudUploadError.staleOwner }
            catch { blocked = true }
        }
        return blocked
    }
}
