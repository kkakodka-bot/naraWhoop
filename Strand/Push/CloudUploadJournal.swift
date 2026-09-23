import Foundation
import CryptoKit
import NoopPush
import Darwin

enum CloudUploadError: Error, Equatable {
    case unavailable, staleOwner, storageFull, corruptJournal, changedPayload, invalidRequest
    case retryScheduled, invalidReceipt, responseTooLarge
}

struct CloudUploadJob: Codable, Sendable {
    enum Phase: String, Codable { case prepared, transferring, uploaded, responseSaved, receiptSaved, retryPending
        case pausedTerminal = "paused_terminal"
    }
    enum Disposition: String, Codable { case retryable, terminal, authentication, awaitingReceipt, verified }
    enum Operation: String, Codable { case request, objectPut, objectComplete }

    let id: String
    let owner: AccountScope
    var generation: UUID
    let endpoint: String
    let deviceID: String
    let createdAt: Date
    var phase: Phase = .prepared
    var operation: Operation
    var payloadName: String?
    var payloadSHA256: String?
    var payloadBytes: Int = 0
    var method: String
    var headers: [String: String]
    var objectID: String?
    var objectKey: String?
    var verifiedObjectKey: String?
    var manifest: Data?
    var lanePath: String?
    var completionMode: PushObjectCompletionMode?
    var signedURL: String?
    var signedHeaders: [String: String] = [:]
    var signedExpiry: Date?
    var needsNewIntent = false
    var attempt: UUID?
    var taskIdentifier: Int?
    var transportKind: CloudUploadTransportKind?
    var ordinaryOpportunityID: UUID?
    var ordinaryAttemptOperation: String?
    var ordinaryCancellationRequested: Bool?
    var failures = 0
    var nextAttemptAt: Date?
    var responseStatus: Int?
    var responseBody: Data?
    var responseRetryAfter: String?
    var responseCode: String?
    var responseDisposition: Disposition?
    var responseAttempt: UUID?
    var authenticationRefreshCount: Int?
    var authenticationRefreshPending: Bool?
    /// Nonsecret digest of the credential actually submitted; never a bearer or refresh token.
    var credentialVersion: String?
    var authenticationRejectedVersion: String?
    var authenticationRefreshedVersion: String?
    var legacyAuthenticationRecoveryCount: Int?
    /// One persisted retry for ACKs produced by the pre-durability receiver contract.
    var receiptUpgradeRetryCount: Int?
    /// One prompt replay after a process restart for a retained retryable server failure.
    var serverRetryRecoveryCount: Int?
    var fleetAuthorizationApplied: Bool?
    var signedURLRenewalCount: Int?
    /// Identity of signed URL, headers and expiry; immutable object/payload identity is separate.
    var signedIntentVersion: String?
    var consecutiveFreshIntentDenials: Int?
    var acknowledged = false
    var receiverStateID: String = ""
    var batchID: String?
    var allowsCellular: Bool?
    var allowsConstrained: Bool?
    var validatedReceipt: PushDurabilityReceipt?
    var correlation: UUID?
    var preparedSelectionID: String?
    var deliveryAdmitted: Bool?
    var localVersion: Int?

    var taskDescription: String? {
        attempt.map { "\(id):\($0.uuidString)" + (transportKind.map { ":" + $0.rawValue } ?? "") }
    }
    var context: AccountSessionContext { .init(scope: owner, generation: generation) }
    var response: PushTransportResponse? {
        guard let status = responseStatus, let body = responseBody else { return nil }
        return .init(statusCode: status, body: body, retryAfter: responseRetryAfter)
    }
}

/// Control responses cannot release source data. Their retry state survives process death.
struct CloudControlOutcome: Codable, Sendable {
    let id: String
    let owner: AccountScope
    var failures = 0
    var nextAttemptAt: Date?
    var status: Int?
    var receiverCode: String?
    var retryAfter: String?
    var disposition: CloudUploadJob.Disposition?
    var authenticationRefreshCount = 0
    var authenticationRefreshPending = false
    var credentialVersion: String?
    var authenticationRejectedVersion: String?
    var authenticationRefreshedVersion: String?
    var legacyAuthenticationRecoveryCount: Int?
    var paused = false
    var responseValidated = false
    var responseAttempt: UUID?
}

struct CloudReceiptCheckpoint: Codable {
    let owner: AccountScope
    let verifiedAt: Date
}

/// Only the upload actor accesses this journal. Payloads never change after their metadata commits.
final class CloudUploadJournal: @unchecked Sendable {
    let directory: URL
    let maximumBytes: Int
    private let fm = FileManager.default
    private let afterWrite: (@Sendable (URL) throws -> Void)?
    private let allowsPreparation: @Sendable () -> Bool
    private let allowsSelectionRead: @Sendable (Bool) -> Bool
    private var validatedOwner: AccountScope?
    let metadata: CloudMetadataStore
    private(set) var selectionIndex: [String: CloudSelectionIndex] = [:]
    private var cachedSelection: CloudPushPreparedSelection?
    var cachedSelectionCount: Int { cachedSelection == nil ? 0 : 1 }
    private(set) var continuations: [String: CloudPreparedContinuation] = [:]
    private var reservations: [String: CloudPreparedQuota.Reservation] = [:]
    private var pendingReservationID: String?
    private var requiresReload = false
    var quota: CloudPreparedQuota { .init(maximumBytes: maximumBytes) }

    init(directory: URL, maximumBytes: Int = 1_073_741_824,
         afterWrite: (@Sendable (URL) throws -> Void)? = nil,
         allowsPreparation: (@Sendable () -> Bool)? = nil,
         resourceBudget: ResourceBudget = .shared) throws {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.afterWrite = afterWrite
        self.allowsPreparation = allowsPreparation ?? { resourceBudget.permits(.cloudPreparation) }
        self.allowsSelectionRead = { legacy in
            allowsPreparation?() ?? resourceBudget.permits(legacy ? .bulk : .cloudControl)
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                             ofItemAtPath: directory.path)
        #endif
        metadata = try CloudMetadataStore(directory: directory)
        try syncDirectory()
    }

    private struct PackingIntent: Codable { let id: UUID; let maximumBytes: Int }
    private struct WireIntent: Codable { let name: String; let bytes: Int }

    func beginBinaryPreparation(maximumWireBytes: Int) throws -> PushBinaryPreparation {
        guard permitsPreparation(), maximumWireBytes > 0, maximumWireBytes <= 4 * 1_048_576 + 64 * 1024,
              try metadata.names(kind: "packing").isEmpty else { throw CloudUploadError.retryScheduled }
        let accounting = try storageAccounting()
        guard accounting.used <= maximumBytes - maximumWireBytes,
              accounting.reserved <= maximumBytes - maximumWireBytes - accounting.used else { throw CloudUploadError.storageFull }
        let id = UUID(), name = "packing-" + UUID().uuidString.lowercased()
        let intent = PackingIntent(id: id, maximumBytes: maximumWireBytes)
        try metadata.transaction {
            try metadata.put(name + ".packing", data: JSONEncoder().encode(intent))
            try metadata.recordFile(name, bytes: maximumWireBytes)
        }
        let path = directory.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: path.path)
        #endif
        try syncDirectory()
        return .init(id: id, directory: path)
    }

    func finishBinaryPreparation(_ preparation: PushBinaryPreparation) throws {
        let name = preparation.directory.lastPathComponent
        guard preparation.directory.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              name.hasPrefix("packing-"), UUID(uuidString: String(name.dropFirst(8))) != nil else { throw CloudUploadError.invalidRequest }
        guard let bytes = try metadata.read(name + ".packing") else { return }
        let intent = try JSONDecoder().decode(PackingIntent.self, from: bytes)
        guard intent.id == preparation.id else { throw CloudUploadError.staleOwner }
        if fm.fileExists(atPath: preparation.directory.path) {
            let info = try preparation.directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isDirectory == true, info.isSymbolicLink != true else { throw CloudUploadError.corruptJournal }
            for file in try fm.contentsOfDirectory(at: preparation.directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                let name = file.lastPathComponent
                let allowed = (name.hasPrefix(".prepare-") && UUID(uuidString: String(name.dropFirst(9))) != nil)
                    || (name.hasSuffix(".body") && Self.validID(String(name.dropLast(5))))
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard allowed, info.isRegularFile == true, info.isSymbolicLink != true else { throw CloudUploadError.corruptJournal }
                try fm.removeItem(at: file) // Only unpublished encoder scratch; adopted wire files have independent hard links.
            }
            try fm.removeItem(at: preparation.directory)
            try syncDirectory()
        }
        try metadata.transaction {
            try metadata.remove(name + ".packing"); try metadata.forgetFile(name)
        }
    }

    func recoverBinaryPreparations() throws {
        for name in try metadata.names(kind: "packing") {
            guard let bytes = try metadata.read(name) else { throw CloudUploadError.corruptJournal }
            let intent = try JSONDecoder().decode(PackingIntent.self, from: bytes)
            try finishBinaryPreparation(.init(id: intent.id, directory: directory.appendingPathComponent(String(name.dropLast(8)), isDirectory: true)))
        }
    }

    private func adoptWire(_ file: PushImmutablePayloadFile, selectionID: String) throws {
        let parent = file.url.deletingLastPathComponent().standardizedFileURL
        let isPackingDirectory = parent.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
            && parent.lastPathComponent.hasPrefix("packing-")
        let ownsPackingDirectory = isPackingDirectory ? try metadata.contains(parent.lastPathComponent + ".packing") : false
        guard parent == directory.standardizedFileURL || ownsPackingDirectory else { throw CloudUploadError.staleOwner }
        try file.verify()
        let destination = directory.appendingPathComponent(file.name)
        try metadata.transaction {
            try metadata.put(selectionID + ".wireintent", data: JSONEncoder().encode(WireIntent(name: file.name, bytes: file.byteCount)))
            try metadata.recordFile(file.name, bytes: file.byteCount)
        }
        if !fm.fileExists(atPath: destination.path) {
            guard Darwin.link(file.url.path, destination.path) == 0 else { throw CloudUploadError.storageFull }
        }
        _ = try PushImmutablePayloadFile(url: destination, byteCount: file.byteCount, sha256: file.sha256)
        // Retry directory durability even when a previous attempt already linked the file.
        try syncDirectory()
    }

    private func recoverWirePublications() throws {
        for name in try metadata.names(kind: "wireintent") {
            guard let bytes = try metadata.read(name) else { throw CloudUploadError.corruptJournal }
            let intent = try JSONDecoder().decode(WireIntent.self, from: bytes)
            guard intent.name.hasSuffix(".wire"), Self.validID(String(intent.name.dropLast(5))), intent.bytes > 0 else { throw CloudUploadError.corruptJournal }
            if !selectionIndex.values.contains(where: { $0.wireFile == intent.name }) {
                try unlinkFile(directory.appendingPathComponent(intent.name))
            }
            try metadata.remove(name)
        }
    }

    func persistBody(_ file: PushImmutablePayloadFile, job: inout CloudUploadJob) throws {
        try file.verify()
        if let prior = job.payloadSHA256 {
            guard prior == file.sha256, job.payloadBytes == file.byteCount else { throw CloudUploadError.changedPayload }
            try verifyBody(job); return
        }
        guard !requiresReload, pendingReservationID == nil, let id = job.preparedSelectionID,
              let index = selectionIndex[id], let state = continuations[id], index.jobIDs(state).contains(job.id),
              index.wireFile == file.name, index.wireBytes == file.byteCount else { throw CloudUploadError.corruptJournal }
        let destination = directory.appendingPathComponent(job.id + ".body")
        try metadata.recordFile(destination.lastPathComponent, bytes: file.byteCount)
        if !fm.fileExists(atPath: destination.path) {
            guard Darwin.link(file.url.path, destination.path) == 0 else { throw CloudUploadError.storageFull }
        }
        try syncDirectory()
        job.payloadName = destination.lastPathComponent; job.payloadSHA256 = file.sha256; job.payloadBytes = file.byteCount
        try verifyBody(job)
    }

    func close() { cachedSelection = nil; metadata.close() }
    func permitsPreparation() -> Bool { allowsPreparation() }

    func load() throws -> [String: CloudUploadJob] {
        var jobs: [String: CloudUploadJob] = [:]
        for name in try metadata.names(kind: "json") {
            let url = directory.appendingPathComponent(name)
            guard let bytes = try metadata.read(name) else { throw CloudUploadError.corruptJournal }
            let job = try JSONDecoder().decode(CloudUploadJob.self, from: bytes)
            guard job.id == url.deletingPathExtension().lastPathComponent,
                  Self.validID(job.id), jobs[job.id] == nil else { throw CloudUploadError.corruptJournal }
            guard job.preparedSelectionID == nil ? (job.localVersion == nil || job.localVersion == 1) : job.localVersion == 2 else {
                throw CloudUploadError.corruptJournal
            }
            if let name = job.payloadName {
                guard name == "\(job.id).body" else { throw CloudUploadError.corruptJournal }
            }
            jobs[job.id] = job
        }
        return jobs
    }

    func save(_ job: CloudUploadJob) throws {
        guard Self.validID(job.id) else { throw CloudUploadError.corruptJournal }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(job)
        if let selectionID = job.preparedSelectionID {
            guard let selection = selectionIndex[selectionID], let state = continuations[selectionID],
                  job.localVersion == 2, selection.jobIDs(state).contains(job.id), bytes.count <= 128 * 1024 else { throw CloudUploadError.corruptJournal }
        }
        try durableWrite(bytes, to: directory.appendingPathComponent("\(job.id).json"))
    }

    func loadControlOutcomes(owner: AccountScope) throws -> [String: CloudControlOutcome] {
        var values: [String: CloudControlOutcome] = [:]
        for name in try metadata.names(kind: "control") {
            let url = directory.appendingPathComponent(name)
            guard let bytes = try metadata.read(name) else { throw CloudUploadError.corruptJournal }
            guard bytes.count <= 16 * 1024 else { throw CloudUploadError.corruptJournal }
            let value = try JSONDecoder().decode(CloudControlOutcome.self, from: bytes)
            guard value.owner == owner, Self.validID(value.id),
                  url.lastPathComponent == value.id + ".control" else { throw CloudUploadError.staleOwner }
            values[value.id] = value
        }
        return values
    }

    func saveControlOutcome(_ value: CloudControlOutcome) throws {
        guard Self.validID(value.id) else { throw CloudUploadError.corruptJournal }
        try durableWrite(JSONEncoder().encode(value), to: directory.appendingPathComponent(value.id + ".control"))
    }

    func removeControlOutcome(_ id: String) throws {
        guard Self.validID(id) else { throw CloudUploadError.corruptJournal }
        try unlinkFile(directory.appendingPathComponent(id + ".control"))
        try syncDirectory()
    }

    func receiptCheckpoint(owner: AccountScope) throws -> Date? {
        let url = directory.appendingPathComponent("last-verified.receipt")
        guard let bytes = try metadata.read(url.lastPathComponent) else { return nil }
        let value = try JSONDecoder().decode(CloudReceiptCheckpoint.self, from: bytes)
        guard value.owner == owner else { throw CloudUploadError.staleOwner }
        return value.verifiedAt
    }

    func saveReceiptCheckpoint(owner: AccountScope, at date: Date) throws {
        try durableWrite(JSONEncoder().encode(CloudReceiptCheckpoint(owner: owner, verifiedAt: date)),
            to: directory.appendingPathComponent("last-verified.receipt"))
    }

    func persistBody(_ body: Data, job: inout CloudUploadJob) throws {
        let hash = Self.digest(body)
        if let prior = job.payloadSHA256 {
            guard prior == hash, job.payloadBytes == body.count else { throw CloudUploadError.changedPayload }
            try verifyBody(job)
            return
        }
        guard !requiresReload, pendingReservationID == nil else { throw CloudUploadError.retryScheduled }
        let name = "\(job.id).body"
        let url = directory.appendingPathComponent(name)
        // A crash after body creation but before metadata commit leaves an adoptable immutable file.
        if fm.fileExists(atPath: url.path) {
            guard try Self.digest(Data(contentsOf: url)) == hash else { throw CloudUploadError.changedPayload }
        } else {
            if job.preparedSelectionID == nil {
                let accounting = try storageAccounting()
                guard body.count <= maximumBytes, accounting.used <= maximumBytes - body.count,
                      accounting.reserved <= maximumBytes - body.count - accounting.used else { throw CloudUploadError.storageFull }
            } else {
                guard let id = job.preparedSelectionID, let selection = selectionIndex[id], let state = continuations[id],
                      selection.jobIDs(state).contains(job.id) else { throw CloudUploadError.corruptJournal }
            }
            try durableWrite(body, to: url)
        }
        job.payloadName = name
        job.payloadSHA256 = hash
        job.payloadBytes = body.count
    }

    func bodyURL(_ job: CloudUploadJob) throws -> URL {
        guard let name = job.payloadName, name == "\(job.id).body" else { throw CloudUploadError.corruptJournal }
        return directory.appendingPathComponent(name)
    }

    func verifyBody(_ job: CloudUploadJob) throws {
        let url = try bodyURL(job)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes = 0
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            bytes += data.count
            hasher.update(data: data)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hash == job.payloadSHA256, bytes == job.payloadBytes else { throw CloudUploadError.changedPayload }
    }

    func emptyBodyURL() throws -> URL {
        let url = directory.appendingPathComponent("completion.body")
        if !fm.fileExists(atPath: url.path) { try durableWrite(Data(), to: url) }
        return url
    }

    func removeCommitted(_ job: CloudUploadJob) throws {
        guard job.acknowledged, Self.validID(job.id) else { throw CloudUploadError.invalidReceipt }
        if job.payloadName != nil {
            try unlinkFile(bodyURL(job))
        }
        let metadata = directory.appendingPathComponent("\(job.id).json")
        try unlinkFile(metadata)
        try syncDirectory()
    }

    func unlinkFile(_ url: URL) throws {
        if Self.isMetadata(url) { try metadata.remove(url.lastPathComponent); return }
        // Unlike removeItem, unlink cannot recursively erase an unexpected directory at this path.
        guard Darwin.unlink(url.path) != 0 else {
            try syncDirectory(); try metadata.forgetFile(url.lastPathComponent); return
        }
        let code = errno
        guard code != ENOENT else { try metadata.forgetFile(url.lastPathComponent); return }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func isMetadata(_ url: URL) -> Bool {
        ["json", "selection", "selection-index", "continuation", "control", "progress", "receipt"].contains(url.pathExtension)
    }

    func durableWrite(_ data: Data, to url: URL) throws {
        if Self.isMetadata(url) {
            try metadata.put(url.lastPathComponent, data: data)
            try afterWrite?(url)
            return
        }
        try metadata.recordFile(url.lastPathComponent, bytes: data.count)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try syncDirectory()
        try afterWrite?(url)
    }

    func syncDirectory() throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw CloudUploadError.corruptJournal }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CloudUploadError.corruptJournal }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func validID(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy { "0123456789abcdef".contains($0) }
    }

    func loadSelections(owner: AccountScope) throws {
        guard pendingReservationID == nil else { throw CloudUploadError.retryScheduled }
        try metadata.validateOwner(owner.namespace)
        validatedOwner = owner
        requiresReload = true
        try CloudSelectionSpool.recoverPublications(journal: self)
        var indices: [String: CloudSelectionIndex] = [:]
        var states: [String: CloudPreparedContinuation] = [:]
        var allocations: [String: CloudPreparedQuota.Reservation] = [:]
        var lanes: Set<String> = []
        for name in try metadata.names(kind: "selection") {
            let id = String(name.dropLast(10))
            guard Self.validID(id) else { throw CloudUploadError.corruptJournal }
            let index: CloudSelectionIndex
            if let bytes = try metadata.read(id + ".selection-index") {
                index = try JSONDecoder().decode(CloudSelectionIndex.self, from: bytes)
                struct Version: Decodable { let version: Int }
                guard !index.isLegacy, let manifest = try metadata.read(name),
                      try JSONDecoder().decode(Version.self, from: manifest).version == CloudPushPreparedSelection.formatVersion else { throw CloudUploadError.corruptJournal }
            } else {
                // Runtime construction must remain possible while BLE/heat denies bulk work.
                // Inspect scalar membership now; decode and migrate one lane only when admitted.
                guard let bytes = try metadata.read(name) else { throw CloudUploadError.corruptJournal }
                index = try CloudSelectionIndex(legacy: bytes, owner: owner)
            }
            try index.validate(owner: owner)
            guard index.id == id, lanes.insert(index.laneID).inserted else { throw CloudUploadError.corruptJournal }
            let state: CloudPreparedContinuation
            if let bytes = try metadata.read(id + ".continuation") {
                guard bytes.count <= 64 * 1024 else { throw CloudUploadError.corruptJournal }
                state = try JSONDecoder().decode(CloudPreparedContinuation.self, from: bytes)
            } else { state = .init(selectionID: id, objectIDs: index.objectID.map { [$0] } ?? []) }
            try state.validate(index)
            indices[id] = index; states[id] = state; allocations[id] = index.reservation
        }
        for name in try metadata.names(kind: "continuation") {
            guard indices[String(name.dropLast(13))] != nil else { throw CloudUploadError.corruptJournal }
        }
        // Validate every lane/version before exposing any queue state. Legacy blobs remain unchanged.
        selectionIndex = indices; continuations = states; reservations = allocations
        cachedSelection = nil; requiresReload = false
        try recoverWirePublications()
        for name in try metadata.names(kind: "retirement") {
            guard let bytes = try metadata.read(name) else { throw CloudUploadError.corruptJournal }
            let index = try JSONDecoder().decode(CloudSelectionIndex.self, from: bytes)
            try index.validate(owner: owner)
            guard name == index.id + ".retirement", selectionIndex[index.id] == nil else { throw CloudUploadError.corruptJournal }
            try finishRetirement(index)
        }
    }

    func selection(_ id: String) throws -> CloudPushPreparedSelection? {
        if cachedSelection?.id == id { return cachedSelection }
        guard let index = selectionIndex[id] else { return nil }
        guard allowsSelectionRead(index.isLegacy) else { throw CloudUploadError.retryScheduled }
        guard let bytes = try metadata.read(id + ".selection") else { throw CloudUploadError.corruptJournal }
        let value: CloudPushPreparedSelection
        if index.isLegacy {
            value = try CloudPushPreparedSelection.decode(bytes)
            guard try index.matches(value), bytes.count == index.legacyEncodedBytes else { throw CloudUploadError.changedPayload }
            let allocation = try quota.reservation(for: value)
            let encoded = try CloudSelectionSpool.encode(value, journal: self, reservation: allocation)
            let converted = CloudSelectionIndex(value, reservation: allocation, segment: encoded.segment, bytes: encoded.bytes)
            try metadata.transaction {
                try metadata.put(id + ".selection", data: encoded.manifest)
                try metadata.put(id + ".selection-index", data: JSONEncoder().encode(converted))
                try metadata.recordFile(encoded.segment, bytes: encoded.bytes)
                try metadata.forgetFile(encoded.pending)
                try metadata.remove(id + ".spoolintent")
            }
            selectionIndex[id] = converted; reservations[id] = allocation
        } else { value = try CloudSelectionSpool.decode(bytes, index: index, directory: directory) }
        cachedSelection = value
        return value
    }

    func reserve(_ value: CloudPushPreparedSelection, legacyJobs: Int) throws {
        guard !requiresReload else { throw CloudUploadError.corruptJournal }
        try metadata.validateOwner(value.owner.namespace)
        validatedOwner = value.owner
        guard pendingReservationID == nil || pendingReservationID == value.id else { throw CloudUploadError.retryScheduled }
        guard (0...quota.maximumJobs).contains(legacyJobs) else { throw CloudUploadError.storageFull }
        if let prior = try selection(value.id) {
            guard prior.progressNamespace == value.progressNamespace,
                  try prior.selection.identityData() == value.selection.identityData(), prior.inlineGzip == value.inlineGzip else { throw CloudUploadError.changedPayload }
            if pendingReservationID == prior.id { try finishReservation(prior) }
            return
        }
        guard !selectionIndex.values.contains(where: { $0.laneID == value.laneID }) else { throw CloudUploadError.retryScheduled }
        let accounting = try storageAccounting()
        let allocations = Array(reservations.values)
        let allocation = try quota.reservation(for: value)
        let reservedFiles = allocations.reduce(0) { $0 + 8 + $1.jobSlots * 3 }
        guard accounting.files <= 2048 - reservedFiles - (8 + allocation.jobSlots * 3) else { throw CloudUploadError.storageFull }
        try quota.admit(allocation, occupiedBytes: accounting.used,
            reservedBytes: accounting.reserved + legacyJobs * CloudPreparedQuota.jobMetadataBytes, groups: selectionIndex.count,
            jobs: legacyJobs + allocations.reduce(0) { $0 + $1.jobSlots })
        cachedSelection = value
        selectionIndex[value.id] = .init(value, reservation: allocation, segment: String(repeating: "0", count: 64) + ".segment", bytes: 0)
        reservations[value.id] = allocation
        continuations[value.id] = .init(selectionID: value.id, objectIDs: value.selection.objectManifest.map { [$0.objectId] } ?? [])
        pendingReservationID = value.id
        try finishReservation(value)
    }

    private func finishReservation(_ value: CloudPushPreparedSelection) throws {
        guard pendingReservationID == value.id, let state = continuations[value.id], let allocation = reservations[value.id],
              !state.published, !state.sourceCommitted else { throw CloudUploadError.corruptJournal }
        // A failed post-commit observer may leave a saved snapshot. Never overwrite unknown or changed evidence.
        var existingIndex: CloudSelectionIndex?
        if let bytes = try metadata.read(value.id + ".selection") {
            guard let indexBytes = try metadata.read(value.id + ".selection-index") else { throw CloudUploadError.corruptJournal }
            let persistedIndex = try JSONDecoder().decode(CloudSelectionIndex.self, from: indexBytes)
            try persistedIndex.validate(owner: value.owner)
            let persisted = try CloudSelectionSpool.decode(bytes, index: persistedIndex, directory: directory)
            guard try persisted.compactEncoded() == value.compactEncoded() else { throw CloudUploadError.changedPayload }
            existingIndex = persistedIndex
        }
        if let bytes = try metadata.read(value.id + ".continuation") {
            let persisted = try JSONDecoder().decode(CloudPreparedContinuation.self, from: bytes)
            try persisted.validate(value)
            guard persisted.published == state.published, persisted.sourceCommitted == state.sourceCommitted,
                  persisted.objectIDs == state.objectIDs, persisted.conflictedObjectIDs == state.conflictedObjectIDs else { throw CloudUploadError.corruptJournal }
        }
        if let index = existingIndex {
            selectionIndex[value.id] = index
            if value.selection.objectPayloadFile != nil { cachedSelection = nil }
            try afterWrite?(directory.appendingPathComponent(value.id + ".selection"))
            try afterWrite?(continuationURL(value.id))
            pendingReservationID = nil
            return
        }
        if let file = value.selection.objectPayloadFile { try adoptWire(file, selectionID: value.id) }
        let encoded = try CloudSelectionSpool.encode(value, journal: self, reservation: allocation)
        let index = CloudSelectionIndex(value, reservation: allocation, segment: encoded.segment, bytes: encoded.bytes)
        try metadata.transaction {
            try metadata.put(value.id + ".selection", data: encoded.manifest)
            try metadata.put(value.id + ".selection-index", data: JSONEncoder().encode(index))
            try metadata.put(value.id + ".continuation", data: JSONEncoder().encode(state))
            try metadata.recordFile(encoded.segment, bytes: encoded.bytes)
            try metadata.forgetFile(encoded.pending)
            try metadata.remove(value.id + ".spoolintent")
            try metadata.remove(value.id + ".wireintent")
        }
        selectionIndex[value.id] = index
        // Decode the published file reference against the account root after scratch is retired.
        if value.selection.objectPayloadFile != nil { cachedSelection = nil }
        try afterWrite?(directory.appendingPathComponent(value.id + ".selection"))
        try afterWrite?(continuationURL(value.id))
        pendingReservationID = nil
    }

    func saveContinuation(_ state: CloudPreparedContinuation) throws {
        guard let index = selectionIndex[state.selectionID] else { throw CloudUploadError.corruptJournal }
        try state.validate(index)
        let bytes = try JSONEncoder().encode(state)
        guard bytes.count <= 64 * 1024 else { throw CloudUploadError.corruptJournal }
        try durableWrite(bytes, to: continuationURL(state.selectionID))
        continuations[state.selectionID] = state
    }

    /// Progress-store pending debt remains durable until retirement completes. Legacy metadata stays
    /// retained and is never re-imported after the SQLite authority marker commits.
    func retireSelection(_ id: String) throws {
        guard Self.validID(id) else { throw CloudUploadError.corruptJournal }
        if let state = continuations[id] { guard state.sourceCommitted else { throw CloudUploadError.invalidReceipt } }
        else if try metadata.contains(id + ".selection") { throw CloudUploadError.invalidReceipt }
        let index: CloudSelectionIndex?
        if let current = selectionIndex[id] { index = current }
        else if let bytes = try metadata.read(id + ".retirement") { index = try JSONDecoder().decode(CloudSelectionIndex.self, from: bytes) }
        else { index = nil }
        if let index {
            guard let owner = validatedOwner, index.id == id else { throw CloudUploadError.corruptJournal }
            try index.validate(owner: owner)
        }
        try metadata.transaction {
            if let index { try metadata.put(id + ".retirement", data: JSONEncoder().encode(index)) }
            try metadata.remove(id + ".continuation")
            try metadata.remove(id + ".selection")
            try metadata.remove(id + ".selection-index")
        }
        continuations[id] = nil; selectionIndex[id] = nil; reservations[id] = nil
        if cachedSelection?.id == id { cachedSelection = nil }
        if let index { try finishRetirement(index) }
    }
    private func finishRetirement(_ index: CloudSelectionIndex) throws {
        guard let owner = validatedOwner else { throw CloudUploadError.corruptJournal }
        try index.validate(owner: owner)
        if !index.isLegacy, !selectionIndex.values.contains(where: { $0.segment == index.segment }) {
            try unlinkFile(directory.appendingPathComponent(index.segment))
        }
        if let wire = index.wireFile, !selectionIndex.values.contains(where: { $0.wireFile == wire }) {
            try unlinkFile(directory.appendingPathComponent(wire))
        }
        try metadata.remove(index.id + ".retirement")
    }

    private func continuationURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".continuation") }

    func storageAccounting() throws -> (used: Int, reserved: Int, files: Int) {
        let accounting = try metadata.accounting()
        var reserved = 0
        for index in selectionIndex.values {
            guard let state = continuations[index.id], let allocation = reservations[index.id] else { throw CloudUploadError.corruptJournal }
            let names = [index.id + ".selection", index.id + ".selection-index", index.id + ".continuation"]
                + index.jobIDs(state).map { $0 + ".json" }
            var allocated = index.isLegacy ? 0 : try metadata.fileBytes(index.segment)
            if let wire = index.wireFile { allocated += try metadata.fileBytes(wire) }
            for name in names { allocated += try metadata.metadataBytes(name) }
            for id in index.jobIDs(state) { allocated += try metadata.fileBytes(id + ".body") }
            let remaining = max(0, allocation.total - allocated)
            guard reserved <= Int.max - remaining else { throw CloudUploadError.storageFull }
            reserved += remaining
        }
        return (accounting.used, reserved, accounting.files)
    }
}
