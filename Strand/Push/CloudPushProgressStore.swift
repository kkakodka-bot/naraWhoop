import Foundation
import NoopPush
import Darwin

/// Account/receiver-scoped, fsynced progress and cleanup debt in one atomic state file.
/// Legacy UserDefaults cursors have no receipt association and are intentionally replayed.
actor CloudPushProgressStore: PushProgressStore {
    private struct State: Codable {
        var devices: Set<String> = []
        var cursors: [String: PushCursor] = [:]
        var windows: [String: PushWindowProgress] = [:]
        var objects: [String: PushInFlightObject] = [:]
        var pending: [String: PushSourceCommit] = [:]
        var preparedReferences: [String: String]?
    }
    private struct Association: Codable {
        let manifest: PushObjectManifest?
        let receipt: PushDurabilityReceipt
        let rowIDs: [Int64]
        let endCursor: PushCursor?
        // A binary association is already a complete, verified source batch. Persist its cleanup
        // intent WITH the receipt: a process death before stage() must not orphan an old version.
        // Legacy and multipart inline associations have no independently recoverable intent.
        let sourceCommit: PushSourceCommit?
        var preparedSelectionID: String?
        var preparedCommit: PushSourceCommit?
    }
    private let journal: CloudUploadJournal
    private let file: URL
    private let auxiliaryIdentityV2: Bool
    private let namespace: String
    private var state: State

    init(namespace: String, directory: URL, auxiliaryIdentityV2: Bool = false) throws {
        self.auxiliaryIdentityV2 = auxiliaryIdentityV2
        self.namespace = namespace
        journal = try CloudUploadJournal(directory: directory)
        file = Self.stateFile(namespace: namespace, directory: directory)
        state = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: file)) : State()
    }
    static func stateFile(namespace: String, directory: URL) -> URL {
        directory.appendingPathComponent(AccountScope.digest(namespace) + ".progress")
    }
    private func save(_ next: State) throws {
        try journal.durableWrite(JSONEncoder().encode(next), to: file)
        state = next
    }
    private func key(_ kind: String, _ table: String, _ device: String) -> String {
        let name = auxiliaryIdentityV2 && kind == "binary" && table == "v18AuxSample"
            ? "v18AuxSample.identity-v2" : table
        return kind + ":" + name + ":" + AccountScope.digest(device)
    }
    func knownDeviceIds() async throws -> Set<String> { state.devices }
    func rememberDeviceId(_ deviceId: String) async throws {
        var next = state; next.devices.insert(deviceId); try save(next)
    }
    func cursor(table: PushAppendTable, deviceId: String) async throws -> PushCursor? { state.cursors[key("append", table.wireName, deviceId)] }
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) async throws {
        var next = state; next.cursors[key("append", table.wireName, deviceId)] = cursor; try save(next)
    }
    func binaryCursor(table: PushBinaryTable, deviceId: String) async throws -> PushCursor? { state.cursors[key("binary", table.wireName, deviceId)] }
    func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) async throws {
        var next = state; next.cursors[key("binary", table.wireName, deviceId)] = cursor; try save(next)
    }
    func window(table: PushMutableTable, deviceId: String) async throws -> PushWindowProgress? { state.windows[key("mutable", table.wireName, deviceId)] }
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) async throws {
        var next = state; next.windows[key("mutable", table.wireName, deviceId)] = progress; try save(next)
    }
    func inFlightObject(table: PushBinaryTable, deviceId: String) async throws -> PushInFlightObject? { state.objects[key("binary", table.wireName, deviceId)] }
    func saveInFlightObject(table: PushBinaryTable, deviceId: String, object: PushInFlightObject?) async throws {
        var next = state; next.objects[key("binary", table.wireName, deviceId)] = object; try save(next)
    }
    func pendingCommits() -> [PushSourceCommit] { Array(state.pending.values) }
    func associate(batch: PushBinaryBatch, rows: [PushBinaryRow], receipt: PushDurabilityReceipt,
                   prepared: CloudPushPreparedSelection? = nil) throws {
        if let prepared {
            guard prepared.progressNamespace == namespace,
                  let restored = try prepared.selection.restoredObject(), restored.batch.payload == batch.payload,
                  restored.batch.manifestJSON == batch.manifestJSON,
                  receipt.matches(restored.manifest.replacingObjectId(receipt.objectId), owner: prepared.owner,
                    wireSHA256: PushDurabilityReceipt.sha256(batch.payload), wireBytes: batch.payload.count) else { throw CloudUploadError.invalidReceipt }
        }
        let ids = rows.map { row -> Int64 in
            switch row {
            case .ppgWaveform(let r): return r.rowId
            case .v18Aux(let r): return r.rowId
            case .rawBatch(let r): return r.rowId
            case .rawImuSession(let r): return r.rowId
            }
        }
        let rawIDs = rows.compactMap { row -> String? in
            if case .rawBatch(let value) = row { return value.batchId }; return nil
        }
        let commit = PushSourceCommit(kind: .binary, table: batch.wireName, deviceID: batch.deviceId,
            batchIDs: [batch.batchId], cursor: batch.endCursor, rawBatchIDs: rawIDs)
        let association = Association(manifest: PushObjectManifest(batch: batch).replacingObjectId(receipt.objectId),
                                      receipt: receipt, rowIDs: ids, endCursor: batch.endCursor, sourceCommit: commit)
        // Historical-version discovery only opens existing namespace state files. Make the
        // namespace durable before publishing its first independently recoverable association.
        if !FileManager.default.fileExists(atPath: file.path) { try save(state) }
        try saveAssociation(association, batchID: batch.batchId, prepared: prepared)
    }
    func associateInline(batch: PushBatch, receipt: PushDurabilityReceipt, prepared: CloudPushPreparedSelection? = nil) throws {
        if let prepared {
            guard prepared.progressNamespace == namespace, receipt.matches(batch, owner: prepared.owner),
                  try prepared.selection.restoredInlineBatches().contains(where: { $0.batchId == batch.batchId && $0.body == batch.body }) else { throw CloudUploadError.invalidReceipt }
        }
        let association = Association(manifest: nil, receipt: receipt, rowIDs: [], endCursor: batch.endCursor,
                                      sourceCommit: nil)
        if prepared != nil, !FileManager.default.fileExists(atPath: file.path) { try save(state) }
        try saveAssociation(association, batchID: batch.batchId, prepared: prepared)
    }
    private func saveAssociation(_ value: Association, batchID: String, prepared: CloudPushPreparedSelection?) throws {
        var value = value
        value.preparedSelectionID = prepared?.id; value.preparedCommit = prepared?.commit
        try journal.durableWrite(JSONEncoder().encode(value), to: associationFile(batchID, selectionID: prepared?.id))
    }
    /// Only new, complete binary continuations can be promoted. An old receipt, a cursor, or an
    /// individual mutable part is not sufficient evidence to reconstruct a source commit.
    func recoverAssociatedCommits() throws {
        let pendingBatches = Set(state.pending.values.flatMap(\.batchIDs))
        let prefix = file.lastPathComponent + "."
        let paths = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(),
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "receipt" }
        for path in paths.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let association = try JSONDecoder().decode(Association.self, from: Data(contentsOf: path))
            guard association.preparedSelectionID == nil, let commit = association.sourceCommit else { continue }
            let receipt = association.receipt
            guard commit.kind == .binary, commit.batchIDs == [receipt.batchId], receipt.isValid,
                  path.lastPathComponent == associationFile(receipt.batchId).lastPathComponent,
                  let manifest = association.manifest,
                  commit.table == manifest.stream, commit.deviceID == manifest.deviceId,
                  commit.cursor == association.endCursor, commit.window == nil,
                  receipt.batchId == manifest.batchId, receipt.objectId == manifest.objectId,
                  receipt.sourceId == manifest.sourceId, receipt.stream == manifest.stream,
                  receipt.deviceId == PushDurabilityReceipt.canonicalDevice(owner: receipt.ownerUserId, device: commit.deviceID),
                  receipt.contentSha256 == manifest.contentSha256,
                  receipt.compressedBytes == manifest.compressedBytes,
                  receipt.uncompressedBytes == manifest.uncompressedBytes,
                  receipt.schemaVersion == PushProtocol.schemaVersion(stream: manifest.stream, protocolVersion: manifest.protocolVersion)
            else { throw CloudUploadError.invalidReceipt }
            guard !pendingBatches.contains(receipt.batchId) else { continue }
            try stage(commit)
        }
    }
    private func associationFile(_ batchID: String, selectionID: String? = nil) -> URL {
        let qualified = selectionID.map { "." + $0 } ?? ""
        return file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + "." + AccountScope.digest(batchID) + qualified + ".receipt")
    }
    private func commitKey(_ commit: PushSourceCommit) -> String {
        AccountScope.digest(commit.batchIDs.joined(separator: "\n"))
    }
    func stage(_ commit: PushSourceCommit, preparedSelectionID: String? = nil) throws {
        guard !commit.batchIDs.isEmpty else { throw CloudUploadError.invalidReceipt }
        if let existing = state.pending[commitKey(commit)] {
            guard state.preparedReferences?[commitKey(commit)] == preparedSelectionID,
                  try Self.sameCommit(existing, commit) else { throw CloudUploadError.invalidReceipt }
            return
        }
        var references: Set<String> = []
        var legacyCount = 0
        for batchID in commit.batchIDs {
            let association = try JSONDecoder().decode(Association.self, from: Data(contentsOf: associationFile(batchID, selectionID: preparedSelectionID)))
            guard association.receipt.isValid, association.receipt.batchId == batchID,
                  association.preparedSelectionID == preparedSelectionID else { throw CloudUploadError.invalidReceipt }
            if let reference = association.preparedSelectionID {
                guard let expected = association.preparedCommit, try Self.sameCommit(expected, commit) else { throw CloudUploadError.invalidReceipt }
                references.insert(reference)
            } else { legacyCount += 1 }
        }
        guard references.count <= 1, references.isEmpty || legacyCount == 0 else { throw CloudUploadError.invalidReceipt }
        var next = state; next.pending[commitKey(commit)] = commit
        if let reference = references.first {
            if next.preparedReferences == nil { next.preparedReferences = [:] }
            next.preparedReferences?[commitKey(commit)] = reference
        }
        try save(next)
    }
    func preparedReference(_ commit: PushSourceCommit) -> String? { state.preparedReferences?[commitKey(commit)] }
    private static func sameCommit(_ a: PushSourceCommit, _ b: PushSourceCommit) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(a) == encoder.encode(b)
    }
    /// Progress never becomes durable without debt in the SAME atomic write.
    func apply(_ commit: PushSourceCommit) throws {
        var next = state
        next.pending[commitKey(commit)] = commit
        let k = key(commit.kind.rawValue, commit.table, commit.deviceID)
        if let cursor = commit.cursor { next.cursors[k] = cursor }
        if let window = commit.window { next.windows[k] = window }
        if commit.kind == .binary { next.objects[k] = nil }
        try save(next)
    }
    func settle(_ commit: PushSourceCommit) throws {
        guard state.pending[commitKey(commit)] != nil else { return }
        // The pending commit is the durable unlink intent. Keep it until every association and the
        // directory entry have reached disk, so a crash midway can finish without re-staging receipts.
        for batchID in commit.batchIDs {
            let path = associationFile(batchID, selectionID: state.preparedReferences?[commitKey(commit)]).path
            if Darwin.unlink(path) != 0, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        let descriptor = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw CloudUploadError.corruptJournal }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CloudUploadError.corruptJournal }
        var next = state; next.pending[commitKey(commit)] = nil
        next.preparedReferences?[commitKey(commit)] = nil
        try save(next)
    }
}

/// Protocol changes reset selection cursors, not already-receipted source cleanup obligations.
enum CloudPushProgressRecovery {
    static func recover(admission: AccountPushAdmission, endpoint: String, receiverStateID: String,
                        currentVersion: String, directory: URL,
                        committer: (CloudPushProgressStore) -> CloudPushSourceCommitter) async throws -> CloudPushProgressStore {
        let versions = PushProtocol.capabilitiesAcceptVersions.split(separator: ",").map(String.init).reversed()
        guard versions.contains(currentVersion) else { throw CloudUploadError.invalidRequest }
        var current: CloudPushProgressStore?
        for version in versions {
            try admission.check()
            let namespace = admission.namespace(endpoint: endpoint, protocolVersion: version,
                                                receiverStateID: receiverStateID)
            let path = CloudPushProgressStore.stateFile(namespace: namespace, directory: directory)
            guard version == currentVersion || FileManager.default.fileExists(atPath: path.path) else { continue }
            let progress = try CloudPushProgressStore(namespace: namespace, directory: directory,
                auxiliaryIdentityV2: version == PushProtocol.auxiliaryIdentityVersion)
            try await committer(progress).recover()
            try admission.check()
            if version == currentVersion { current = progress }
        }
        guard let current else { throw CloudUploadError.corruptJournal }
        return current
    }
}

/// Every method closes over one captured owner. Replays run BEFORE selecting more source rows.
struct CloudPushSourceCommitter: Sendable {
    let progress: CloudPushProgressStore
    let check: @Sendable () throws -> Void
    let acknowledge: @Sendable (PushSourceCommit) async throws -> Void
    let cleanup: @Sendable (String) async throws -> Void
    var didApply: @Sendable (PushSourceCommit) async throws -> Void = { _ in }
    var didCleanup: @Sendable (PushSourceCommit) async throws -> Void = { _ in }
    var cleanupPrepared: (@Sendable (String) async throws -> Void)?
    var retirePrepared: (@Sendable (String) async throws -> Void)?

    func commit(_ value: PushSourceCommit, preparedSelectionID: String? = nil) async throws {
        try check()
        try await progress.stage(value, preparedSelectionID: preparedSelectionID)
        try await finish(value)
    }
    func recover() async throws {
        try check()
        for value in await progress.pendingCommits() { try await finish(value) }
        try check()
        try await progress.recoverAssociatedCommits()
        try check()
        for value in await progress.pendingCommits() { try await finish(value) }
    }
    private func finish(_ value: PushSourceCommit) async throws {
        try check()
        try await acknowledge(value)
        try check()
        try await progress.apply(value)
        try check()
        try await didApply(value)
        let preparedID = await progress.preparedReference(value)
        if let preparedID {
            guard let cleanupPrepared else { throw CloudUploadError.invalidReceipt }
            try await cleanupPrepared(preparedID)
        } else {
            for batch in value.batchIDs { try check(); try await cleanup(batch) }
        }
        try check()
        try await didCleanup(value)
        try check()
        if let preparedID {
            guard let retirePrepared else { throw CloudUploadError.invalidReceipt }
            try await retirePrepared(preparedID)
            try check()
        }
        try await progress.settle(value)
    }
}
