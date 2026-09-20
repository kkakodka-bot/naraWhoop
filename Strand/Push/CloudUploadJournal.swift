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
    var signedURL: String?
    var signedHeaders: [String: String] = [:]
    var signedExpiry: Date?
    var needsNewIntent = false
    var attempt: UUID?
    var taskIdentifier: Int?
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

    var taskDescription: String? { attempt.map { "\(id):\($0.uuidString)" } }
    var context: AccountSessionContext { .init(scope: owner, generation: generation) }
    var response: PushTransportResponse? {
        guard let status = responseStatus, let body = responseBody else { return nil }
        return .init(statusCode: status, body: body, retryAfter: responseRetryAfter)
    }
}

/// Only the upload actor accesses this journal. Payloads never change after their metadata commits.
final class CloudUploadJournal: @unchecked Sendable {
    let directory: URL
    let maximumBytes: Int
    private let fm = FileManager.default
    private let afterWrite: (@Sendable (URL) throws -> Void)?
    private(set) var selections: [String: CloudPushPreparedSelection] = [:]
    private(set) var continuations: [String: CloudPreparedContinuation] = [:]
    private var reservations: [String: CloudPreparedQuota.Reservation] = [:]
    private var pendingReservationID: String?
    private var requiresReload = false
    var quota: CloudPreparedQuota { .init(maximumBytes: maximumBytes) }

    init(directory: URL, maximumBytes: Int = 1_073_741_824,
         afterWrite: (@Sendable (URL) throws -> Void)? = nil) throws {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.afterWrite = afterWrite
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
    }

    func load() throws -> [String: CloudUploadJob] {
        var jobs: [String: CloudUploadJob] = [:]
        for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
            let job = try JSONDecoder().decode(CloudUploadJob.self, from: Data(contentsOf: url))
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
            guard let selection = selections[selectionID], let state = continuations[selectionID],
                  job.localVersion == 2, try selection.jobIDs(state).contains(job.id), bytes.count <= 128 * 1024 else { throw CloudUploadError.corruptJournal }
        }
        try durableWrite(bytes, to: directory.appendingPathComponent("\(job.id).json"))
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
                guard let id = job.preparedSelectionID, let selection = selections[id], let state = continuations[id],
                      try selection.jobIDs(state).contains(job.id) else { throw CloudUploadError.corruptJournal }
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
        // Unlike removeItem, unlink cannot recursively erase an unexpected directory at this path.
        guard Darwin.unlink(url.path) != 0 else { return }
        let code = errno
        guard code != ENOENT else { return }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    func durableWrite(_ data: Data, to url: URL) throws {
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
        requiresReload = true
        var loadedSelections: [String: CloudPushPreparedSelection] = [:]
        var loadedContinuations: [String: CloudPreparedContinuation] = [:]
        var loadedReservations: [String: CloudPreparedQuota.Reservation] = [:]
        var lanes: Set<String> = []
        for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "selection" {
            let selection = try CloudPushPreparedSelection.decode(Data(contentsOf: url))
            guard selection.owner == owner, Self.validID(selection.id),
                  url.lastPathComponent == selection.id + ".selection",
                  lanes.insert(selection.laneID).inserted else { throw CloudUploadError.corruptJournal }
            let stateURL = continuationURL(selection.id)
            let state: CloudPreparedContinuation
            if fm.fileExists(atPath: stateURL.path) {
                let bytes = try Data(contentsOf: stateURL)
                guard bytes.count <= 64 * 1024 else { throw CloudUploadError.corruptJournal }
                state = try JSONDecoder().decode(CloudPreparedContinuation.self, from: bytes)
            } else {
                let objectID = selection.selection.objectManifest?.objectId
                state = .init(selectionID: selection.id, objectIDs: objectID.map { [$0] } ?? [])
            }
            try state.validate(selection)
            loadedSelections[selection.id] = selection; loadedContinuations[selection.id] = state
            loadedReservations[selection.id] = try quota.reservation(for: selection)
        }
        // An orphan future/unknown continuation is retained, never interpreted as an empty queue.
        for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "continuation" {
            guard loadedSelections[url.deletingPathExtension().lastPathComponent] != nil else { throw CloudUploadError.corruptJournal }
        }
        selections = loadedSelections; continuations = loadedContinuations; reservations = loadedReservations
        requiresReload = false
    }

    func reserve(_ selection: CloudPushPreparedSelection, legacyJobs: Int) throws {
        guard !requiresReload else { throw CloudUploadError.corruptJournal }
        guard pendingReservationID == nil || pendingReservationID == selection.id else { throw CloudUploadError.retryScheduled }
        guard (0...quota.maximumJobs).contains(legacyJobs) else { throw CloudUploadError.storageFull }
        if let prior = selections[selection.id] {
            // Generation/correlation belong to first capture, not the new authenticated execution.
            guard prior.progressNamespace == selection.progressNamespace,
                  try prior.selection.encoded() == selection.selection.encoded(), prior.inlineGzip == selection.inlineGzip else { throw CloudUploadError.changedPayload }
            if pendingReservationID == prior.id { try finishReservation(prior) }
            return
        }
        guard !selections.values.contains(where: { $0.laneID == selection.laneID }) else { throw CloudUploadError.retryScheduled }
        let accounting = try storageAccounting()
        let reservations = Array(self.reservations.values)
        let allocation = try quota.reservation(for: selection)
        // Include progress receipts and atomic temporary entries, plus all retained orphan files.
        let reservedFiles = reservations.reduce(0) { $0 + 8 + $1.jobSlots * 3 }
        guard accounting.files <= 2048 - reservedFiles - (8 + allocation.jobSlots * 3) else { throw CloudUploadError.storageFull }
        try quota.admit(quota.reservation(for: selection), occupiedBytes: accounting.used,
            reservedBytes: accounting.reserved + legacyJobs * CloudPreparedQuota.jobMetadataBytes, groups: selections.count,
            jobs: legacyJobs + reservations.reduce(0) { $0 + $1.jobSlots })
        // Atomic replacement can succeed before protection/fsync throws. Keep the lane and all
        // completion capacity reserved even then, and publish nothing until this exact intent retries.
        selections[selection.id] = selection
        self.reservations[selection.id] = allocation
        let objectID = selection.selection.objectManifest?.objectId
        let state = CloudPreparedContinuation(selectionID: selection.id, objectIDs: objectID.map { [$0] } ?? [])
        continuations[selection.id] = state
        pendingReservationID = selection.id
        try finishReservation(selection)
    }

    private func finishReservation(_ selection: CloudPushPreparedSelection) throws {
        guard pendingReservationID == selection.id, let state = continuations[selection.id],
              !state.published, !state.sourceCommitted else { throw CloudUploadError.corruptJournal }
        let bytes = try selection.encoded()
        let path = directory.appendingPathComponent(selection.id + ".selection")
        if fm.fileExists(atPath: path.path) {
            guard try Data(contentsOf: path) == bytes else { throw CloudUploadError.changedPayload }
        }
        let statePath = continuationURL(selection.id)
        if fm.fileExists(atPath: statePath.path) {
            let persisted = try JSONDecoder().decode(CloudPreparedContinuation.self, from: Data(contentsOf: statePath))
            try persisted.validate(selection)
            guard persisted.published == state.published, persisted.sourceCommitted == state.sourceCommitted,
                  persisted.objectIDs == state.objectIDs, persisted.conflictedObjectIDs == state.conflictedObjectIDs else {
                throw CloudUploadError.corruptJournal
            }
        }
        try durableWrite(bytes, to: path)
        try saveContinuation(state)
        pendingReservationID = nil
    }

    func saveContinuation(_ state: CloudPreparedContinuation) throws {
        guard let selection = selections[state.selectionID] else { throw CloudUploadError.corruptJournal }
        try state.validate(selection)
        let bytes = try JSONEncoder().encode(state)
        guard bytes.count <= 64 * 1024 else { throw CloudUploadError.corruptJournal }
        try durableWrite(bytes, to: continuationURL(state.selectionID))
        continuations[state.selectionID] = state
    }

    /// Called only while a progress-store pending reference remains durable. Missing files are a
    /// successful replay of a prior unlink, never permission to infer a new cleanup group.
    func retireSelection(_ id: String) throws {
        guard Self.validID(id) else { throw CloudUploadError.corruptJournal }
        if let state = continuations[id] { guard state.sourceCommitted else { throw CloudUploadError.invalidReceipt } }
        try unlinkFile(continuationURL(id))
        try syncDirectory()
        try unlinkFile(directory.appendingPathComponent(id + ".selection"))
        try syncDirectory()
        continuations[id] = nil; selections[id] = nil
        reservations[id] = nil
    }

    private func continuationURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".continuation") }

    func storageAccounting() throws -> (used: Int, reserved: Int, files: Int) {
        let accountingDirectory = directory.resolvingSymlinksInPath()
        var sizes: [String: Int] = [:], used = 0
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: accountingDirectory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in enumerationError = error; return false }) else { throw CloudUploadError.corruptJournal }
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CloudUploadError.corruptJournal }
            if values.isRegularFile == true {
                let size = values.fileSize ?? 0
                guard size >= 0, used <= Int.max - size else { throw CloudUploadError.storageFull }
                used += size; sizes[url.resolvingSymlinksInPath().path] = size
            }
        }
        if let enumerationError { throw enumerationError }
        var reserved = 0
        for selection in selections.values {
            guard let state = continuations[selection.id] else { throw CloudUploadError.corruptJournal }
            guard let allocation = reservations[selection.id] else { throw CloudUploadError.corruptJournal }
            let names = [selection.id + ".selection", selection.id + ".continuation"]
                + (try selection.jobIDs(state)).flatMap { [$0 + ".json", $0 + ".body"] }
            let allocated = names.reduce(0) { $0 + (sizes[accountingDirectory.appendingPathComponent($1).path] ?? 0) }
            let remaining = max(0, allocation.total - allocated)
            guard reserved <= Int.max - remaining else { throw CloudUploadError.storageFull }
            reserved += remaining
        }
        return (used, reserved, sizes.count)
    }
}
