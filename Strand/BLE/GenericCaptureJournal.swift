import Foundation
import WhoopProtocol
import WhoopStore

/// Legacy Streams admission is RAM-only. Prepared StandardHR journals retain original occurrences
/// in the captured account store before publishing a local receipt; neither path resolves a new owner.
@MainActor
final class GenericCaptureJournal {
    typealias Writer = (Streams, String) async throws -> Void
    private struct Batch {
        let streams: Streams
        let deviceID: String
        let bytes: Int
    }
    private struct FinalBuffer {
        let id: ObjectIdentifier
        let flush: () -> Bool
    }
    private let writer: Writer
    private let maxBatches: Int
    private let maxBytes: Int
    private var pending: [Batch] = []
    private var finalBuffers: [FinalBuffer] = []
    private var running: Task<Bool, Never>?
    private var holdNotification: Task<Void, Never>?
    private var sealed = false
    private var flushingAcceptedBuffer = false
    private var standardHR: StandardHRJournalState?
    private var retryTimer: Task<Void, Never>?
    private static var standardHRSlots: [StandardHRSlotKey: WeakStandardHRSlot] = [:]
    private(set) var isHeld = false
    private(set) var pendingBytes = 0
    var pendingBatchCount: Int { standardHR.map { $0.pending.count + ($0.heldSink == nil ? 0 : 1) } ?? pending.count }
    var pendingFinalBufferCount: Int { finalBuffers.count }
    var didHoldCapture: (() -> Void)?
    var didCommitStandardHR: ((StandardHRLocalReceipt) -> Void)?

    init(store: WhoopStore, maxBatches: Int = 256, maxBytes: Int = 1_048_576) {
        self.writer = { [store] streams, deviceID in _ = try await store.insert(streams, deviceId: deviceID) }
        self.maxBatches = max(1, maxBatches)
        self.maxBytes = max(1, maxBytes)
    }

    init(maxBatches: Int = 256, maxBytes: Int = 1_048_576, writer: @escaping Writer) {
        self.writer = writer
        self.maxBatches = max(1, maxBatches)
        self.maxBytes = max(1, maxBytes)
    }

    /// True transfers ownership into this bounded outbox, NOT a durability receipt.
    /// False leaves ownership with the source, which must stop intake and retain its buffer.
    func admit(_ streams: Streams, deviceID: String) -> Bool {
        guard standardHR == nil else { return false }
        guard (!sealed && !isHeld) || flushingAcceptedBuffer else { return false }
        let bytes: Int
        do { bytes = try JSONEncoder().encode(streams).count + deviceID.utf8.count }
        catch { hold(); return false }
        guard pending.count < maxBatches, bytes <= maxBytes - pendingBytes else { hold(); return false }
        pending.append(Batch(streams: streams, deviceID: deviceID, bytes: bytes))
        pendingBytes += bytes
        if !isHeld { startWriteIfNeeded() }
        return true
    }

    /// Captures the real stopped source only if its final accepted buffer could not yet be admitted.
    func retainFinalBuffer(owner: AnyObject, flush: @escaping () -> Bool) {
        let id = ObjectIdentifier(owner)
        guard !finalBuffers.contains(where: { $0.id == id }) else { return }
        finalBuffers.append(FinalBuffer(id: id, flush: flush))
        hold()
    }

    /// Call after synchronously stopping source intake and offering its final buffer.
    func sealCapture() {
        sealed = true
        standardHR?.sinks.forEach { $0.value?.sealIntake() }
        retryTimer?.cancel()
        retryTimer = nil
    }

    /// Joins in-flight work. A failed pass retains the exact batch and final source for a later retry.
    func drain() async -> Bool {
        retryTimer?.cancel()
        retryTimer = nil
        if let running { return await running.value }
        startWriteIfNeeded()
        guard let running else { return pending.isEmpty && finalBuffers.isEmpty }
        return await running.value
    }

    private func startWriteIfNeeded() {
        if let standardHR {
            startStandardHRWriteIfNeeded(standardHR)
            return
        }
        guard running == nil, !pending.isEmpty || !finalBuffers.isEmpty else { return }
        running = Task { [self] in
            defer { running = nil }
            while true {
                if let batch = pending.first {
                    do { try await writer(batch.streams, batch.deviceID) }
                    catch { hold(); return false }
                    pending.removeFirst()
                    pendingBytes -= batch.bytes
                    continue
                }
                // A fast writer must not clear the hold before the coordinator has stopped intake
                // and retained the source's unadmitted suffix. Join that handoff, not just SQLite.
                if let notification = holdNotification {
                    await notification.value
                    continue
                }
                if !finalBuffers.isEmpty {
                    let offered = finalBuffers
                    flushingAcceptedBuffer = true
                    for buffer in offered where buffer.flush() {
                        finalBuffers.removeAll { $0.id == buffer.id }
                    }
                    flushingAcceptedBuffer = false
                    if !pending.isEmpty { continue }
                    if !finalBuffers.isEmpty { hold(); return false }
                }
                isHeld = false
                return true
            }
        }
    }

    private func hold() {
        guard !isHeld else { return }
        isHeld = true
        // Admission can be called inside stop/flush; notify outside that stack to avoid reentrant flush.
        guard holdNotification == nil else { return }
        holdNotification = Task { [weak self] in
            guard let self else { return }
            self.holdNotification = nil
            if self.isHeld { self.didHoldCapture?() }
        }
    }

    static func prepareStandardHR(store: WhoopStore, owner: StandardHRCaptureOwner,
                                  runtimeGeneration: UUID,
                                  hooks: StandardHRJournalHooks = .init()) async throws -> GenericCaptureJournal {
        let rawPath = store.registryWriter.path
        guard !rawPath.isEmpty, rawPath != ":memory:" else { throw StandardHRCaptureError.storageUnavailable }
        let key = StandardHRSlotKey(path: URL(fileURLWithPath: rawPath).standardizedFileURL.path,
                                    projectURL: owner.projectURL, userID: owner.userID)
        standardHRSlots = standardHRSlots.filter { $0.value.value != nil }
        guard standardHRSlots[key]?.value == nil else { throw StandardHRCaptureError.concurrentCapture }
        let slot = StandardHRLiveSlot(key: key)
        standardHRSlots[key] = WeakStandardHRSlot(slot)
        var transferred = false
        defer { if !transferred { releaseStandardHRSlot(slot) } }
        let encoder = StandardHRCaptureEncoder(hooks: hooks)
        try Task.checkCancellation()
        let canonicalPath = try await encoder.canonicalPath(rawPath)
        let canonicalKey = StandardHRSlotKey(path: canonicalPath, projectURL: owner.projectURL, userID: owner.userID)
        if let incumbent = standardHRSlots[canonicalKey]?.value, incumbent !== slot {
            throw StandardHRCaptureError.concurrentCapture
        }
        slot.key = canonicalKey
        slot.keys.insert(canonicalKey)
        standardHRSlots[canonicalKey] = WeakStandardHRSlot(slot)
        try await encoder.checkCapacity(path: canonicalPath, force: true)
        try await hooks.beforeRecovery()
        repeat {
            try Task.checkCancellation()
            let count = try await store.recoverStandardHRCapture(owner: owner, limit: 64)
            if count == 0 { break }
            await Task.yield()
        } while true
        try Task.checkCancellation()
        let session = try await store.beginStandardHRCapture(owner: owner, sessionID: UUID(),
            runtimeGeneration: runtimeGeneration, openedAtUnixSeconds: Int64(Date().timeIntervalSince1970))
        if Task.isCancelled {
            try await store.sealStandardHRCapture(session)
            throw CancellationError()
        }
        let journal = GenericCaptureJournal(store: store)
        journal.standardHR = StandardHRJournalState(store: store, session: session, slot: slot,
                                                    encoder: encoder, hooks: hooks)
        transferred = true
        return journal
    }

    func standardHRSink(deviceID: String) throws -> StandardHRCaptureSink {
        guard let state = standardHR, !sealed, !isHeld, state.slot != nil,
              !deviceID.isEmpty, deviceID.utf8.count <= 256, !deviceID.contains("\0") else {
            throw StandardHRCaptureError.closedSession
        }
        state.sinks.removeAll { $0.value == nil }
        let sink = StandardHRCaptureSink(journal: self, deviceID: deviceID)
        state.sinks.append(WeakStandardHRSink(sink))
        return sink
    }

    fileprivate var canReserveStandardHR: Bool {
        standardHR?.slot != nil && !sealed && !isHeld
    }

    fileprivate func reserveStandardHR(sink: StandardHRCaptureSink, rawBytes: Data,
                                       hostTimestampSeconds: Int64, hr: Int, rrMs: [Int],
                                       contact: StandardHRContact) -> StandardHRReservation {
        guard let state = standardHR, canReserveStandardHR, sink.isOpen,
              !rawBytes.isEmpty, rawBytes.count <= 512, rrMs.count <= 255,
              (0...65535).contains(hr), rrMs.allSatisfy({ (0...63999).contains($0) }),
              Int(exactly: hostTimestampSeconds) != nil,
              state.nextSequence < Int64.max, state.heldSink == nil,
              state.pending.count < 64, pendingBytes <= 1_048_576 - 16_384 else { return .rejected }
        let id: StandardHRCaptureID
        do { id = try StandardHRCaptureID(sessionID: state.session.sessionID, sequence: state.nextSequence) }
        catch { return .rejected }
        let offer = StandardHRPendingOffer(id: id,
            scope: DurableIngestScope(environment: state.session.owner.projectURL,
                accountID: state.session.owner.userID, deviceID: sink.deviceID),
            timestamp: hostTimestampSeconds, rawBytes: rawBytes, hr: hr, rrMs: rrMs, contact: contact)
        state.nextSequence += 1
        pendingBytes += 16_384
        if state.pending.count == 63 {
            sink.heldOffer = offer
            state.heldSink = sink
            hold()
            startWriteIfNeeded()
            return .held(id)
        }
        state.pending.append(StandardHRPendingEntry(offer: offer))
        startWriteIfNeeded()
        return .queued(id)
    }

    fileprivate func transferHeldStandardHR(_ sink: StandardHRCaptureSink) -> Bool {
        guard let offer = sink.heldOffer else { return true }
        guard let state = standardHR, state.heldSink === sink, state.pending.count < 63 else { return false }
        state.pending.append(StandardHRPendingEntry(offer: offer))
        sink.heldOffer = nil
        state.heldSink = nil
        // This is a pre-fence reservation transfer, not new intake or another budget reservation.
        return true
    }

    private func startStandardHRWriteIfNeeded(_ state: StandardHRJournalState) {
        guard running == nil,
              !state.pending.isEmpty || state.heldSink != nil || !finalBuffers.isEmpty
                || holdNotification != nil || (sealed && !state.sessionSealed) else { return }
        running = Task { [self] in
            defer { running = nil }
            do {
                while true {
                    if let entry = state.pending.first {
                        if entry.batch == nil {
                            entry.batch = try await state.encoder.freeze(entry.offer)
                        }
                        guard let batch = entry.batch else { throw StandardHRCaptureError.invalidIntent }
                        if entry.receipt == nil {
                            try await state.encoder.checkCapacity(path: state.path, force: false)
                            try await state.hooks.beforeAppend(batch)
                            let receipt = try await state.store.appendStandardHRCapture(batch, session: state.session)
                            try await state.hooks.afterAppend(receipt)
                            guard receipt.id == batch.id, receipt.intentSHA256 == batch.intentSHA256 else {
                                throw StandardHRCaptureError.integrityFailure
                            }
                            entry.receipt = receipt
                            // Publish only after the committed identity and reservation state are settled.
                            didCommitStandardHR?(receipt)
                        }
                        try await state.hooks.beforeProjection()
                        while true {
                            let step = try await state.store.projectNextStandardHRCapture(owner: state.session.owner)
                            try await state.hooks.afterProjection(step)
                            switch step {
                            case .empty: break
                            case .completed(let id, let digest):
                                if id != batch.id { await Task.yield(); continue }
                                guard digest == batch.intentSHA256 else { throw StandardHRCaptureError.integrityFailure }
                            }
                            break
                        }
                        state.pending.removeFirst()
                        pendingBytes -= 16_384
                        state.failures = 0
                        if let sink = state.heldSink { _ = transferHeldStandardHR(sink) }
                        continue
                    }
                    if let sink = state.heldSink {
                        guard transferHeldStandardHR(sink) else { throw StandardHRCaptureError.capacity }
                        continue
                    }
                    if let notification = holdNotification { await notification.value; continue }
                    if !finalBuffers.isEmpty {
                        let offered = finalBuffers
                        for buffer in offered where buffer.flush() {
                            finalBuffers.removeAll { $0.id == buffer.id }
                        }
                        if !state.pending.isEmpty || state.heldSink != nil { continue }
                        if !finalBuffers.isEmpty { throw StandardHRCaptureError.storageUnavailable }
                    }
                    if sealed && !state.sessionSealed {
                        try await state.store.sealStandardHRCapture(state.session)
                        state.sessionSealed = true
                        if let slot = state.slot {
                            Self.releaseStandardHRSlot(slot)
                            state.slot = nil
                        }
                    }
                    isHeld = false
                    return true
                }
            } catch {
                hold()
                state.failures = min(state.failures + 1, 6)
                scheduleStandardHRRetry(state)
                return false
            }
        }
    }

    private func scheduleStandardHRRetry(_ state: StandardHRJournalState) {
        guard !sealed, state.hooks.automaticRetry, retryTimer == nil else { return }
        let seconds = min(30, 1 << (max(1, state.failures) - 1))
        retryTimer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.retryTimer = nil
            _ = await self.drain()
        }
    }

    private static func releaseStandardHRSlot(_ slot: StandardHRLiveSlot) {
        for key in slot.keys where standardHRSlots[key]?.value === slot { standardHRSlots.removeValue(forKey: key) }
    }

    deinit { retryTimer?.cancel() }
}

enum StandardHRReservation: Equatable {
    case queued(StandardHRCaptureID)
    case held(StandardHRCaptureID)
    case rejected
}

@MainActor
final class StandardHRCaptureSink {
    fileprivate weak var journal: GenericCaptureJournal?
    let deviceID: String
    private var sealed = false
    fileprivate var heldOffer: StandardHRPendingOffer?
    var isOpen: Bool { !sealed && journal?.canReserveStandardHR == true }
    var pendingCaptureCount: Int { heldOffer == nil ? 0 : 1 }

    fileprivate init(journal: GenericCaptureJournal, deviceID: String) {
        self.journal = journal
        self.deviceID = deviceID
    }
    func offer(rawBytes: Data, hostTimestampSeconds: Int64,
               hr: Int, rrMs: [Int], contact: StandardHRContact) -> StandardHRReservation {
        guard isOpen, let journal else { return .rejected }
        return journal.reserveStandardHR(sink: self, rawBytes: rawBytes,
            hostTimestampSeconds: hostTimestampSeconds, hr: hr, rrMs: rrMs, contact: contact)
    }
    func sealIntake() { sealed = true }
    func retryHeldOffer() -> Bool {
        guard heldOffer != nil else { return true }
        return journal?.transferHeldStandardHR(self) ?? false
    }
}

struct StandardHRJournalHooks: Sendable {
    var beforeRecovery: @Sendable () async throws -> Void = {}
    var beforeAppend: @Sendable (StandardHRFrozenBatch) async throws -> Void = { _ in }
    var afterAppend: @Sendable (StandardHRLocalReceipt) async throws -> Void = { _ in }
    var beforeProjection: @Sendable () async throws -> Void = {}
    var afterProjection: @Sendable (StandardHRProjectionStep) async throws -> Void = { _ in }
    var didEncode: @Sendable (Bool) async -> Void = { _ in }
    var availableBytes: (@Sendable (String) async throws -> Int64?)?
    var automaticRetry = true
}

private struct StandardHRSlotKey: Hashable {
    let path: String
    let projectURL: String
    let userID: String
}
private final class StandardHRLiveSlot {
    var key: StandardHRSlotKey
    var keys: Set<StandardHRSlotKey>
    init(key: StandardHRSlotKey) { self.key = key; keys = [key] }
}
private struct WeakStandardHRSlot {
    weak var value: StandardHRLiveSlot?
    init(_ value: StandardHRLiveSlot) { self.value = value }
}
private struct WeakStandardHRSink {
    weak var value: StandardHRCaptureSink?
    init(_ value: StandardHRCaptureSink) { self.value = value }
}
fileprivate struct StandardHRPendingOffer: Sendable {
    let id: StandardHRCaptureID
    let scope: DurableIngestScope
    let timestamp: Int64
    let rawBytes: Data
    let hr: Int
    let rrMs: [Int]
    let contact: StandardHRContact
}
@MainActor
private final class StandardHRPendingEntry {
    let offer: StandardHRPendingOffer
    var batch: StandardHRFrozenBatch?
    var receipt: StandardHRLocalReceipt?
    init(offer: StandardHRPendingOffer) { self.offer = offer }
}
@MainActor
private final class StandardHRJournalState {
    let store: WhoopStore
    let session: StandardHRCaptureSession
    let path: String
    let encoder: StandardHRCaptureEncoder
    let hooks: StandardHRJournalHooks
    var slot: StandardHRLiveSlot?
    var nextSequence: Int64 = 0
    var pending: [StandardHRPendingEntry] = []
    var heldSink: StandardHRCaptureSink?
    var sinks: [WeakStandardHRSink] = []
    var sessionSealed = false
    var failures = 0
    init(store: WhoopStore, session: StandardHRCaptureSession, slot: StandardHRLiveSlot,
         encoder: StandardHRCaptureEncoder, hooks: StandardHRJournalHooks) {
        self.store = store; self.session = session; self.slot = slot
        self.path = slot.key.path; self.encoder = encoder; self.hooks = hooks
    }
}

private actor StandardHRCaptureEncoder {
    private let hooks: StandardHRJournalHooks
    private var lastCapacityCheck: TimeInterval = -.infinity
    private var writesSinceCapacityCheck = 64
    init(hooks: StandardHRJournalHooks) { self.hooks = hooks }

    func canonicalPath(_ path: String) throws -> String {
        guard !path.isEmpty, path != ":memory:" else { throw StandardHRCaptureError.storageUnavailable }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    func freeze(_ offer: StandardHRPendingOffer) async throws -> StandardHRFrozenBatch {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let timestamp = Int(exactly: offer.timestamp) else { throw StandardHRCaptureError.invalidIntent }
        let streams = StandardHRMapping.samples(fromHR: offer.hr, rr: offer.rrMs,
                                                contact: offer.contact, at: timestamp)
        let bytes = try encoder.encode(streams)
        guard bytes.count <= 12_288 else { throw StandardHRCaptureError.capacity }
        let batch = try StandardHRFrozenBatch(id: offer.id, scope: offer.scope,
            hostTimestampSeconds: offer.timestamp, rawBytes: offer.rawBytes, projectionJSON: bytes)
        let onMain = isMainThreadAtEncoding()
        await hooks.didEncode(onMain)
        return batch
    }

    private func isMainThreadAtEncoding() -> Bool { Thread.isMainThread }

    func checkCapacity(path: String, force: Bool) async throws {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || writesSinceCapacityCheck >= 64 || now - lastCapacityCheck >= 5 else {
            writesSinceCapacityCheck += 1
            return
        }
        let available: Int64?
        if let supplied = hooks.availableBytes {
            available = try await supplied(path)
        } else {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                                 .volumeAvailableCapacityKey])
            available = values.volumeAvailableCapacityForImportantUsage
                ?? values.volumeAvailableCapacity.map(Int64.init)
        }
        guard let available, available >= 1_073_741_824 else { throw StandardHRCaptureError.capacity }
        lastCapacityCheck = now
        writesSinceCapacityCheck = 1
    }
}
