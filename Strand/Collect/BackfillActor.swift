import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// Read-only offload session state for `BLEManager.exitBackfilling` (main actor).
struct BackfillSessionSnapshot: Sendable {
    let sessionRowsPersisted: Int
    let sessionMotionRows: Int
    let sessionSkinTempRows: Int
    let sessionNights: Int
    let sessionNightKeys: Set<Int>
    let sessionClockDevice: Int?
    let sessionClockWall: Int?
    let sessionUsedIdentityRef: Bool
    let sessionDroppedImplausible: Int
    let sessionDynAccel: Streams.DynAccelDiag
    let persistStalled: Bool
    let lastAckedTrim: UInt32?
    let family: DeviceFamily
    let phaseSamples: [BackfillChunkPhaseSample]
    let rrEmissionLine: String?
}

/// Main-actor callbacks the serial offload pipeline invokes (BLE writes, UI tallies, archives).
struct BackfillMainHooks: Sendable {
    let ackTrim: @Sendable (UInt32, [UInt8]) async -> Void
    let onBankedOffload: @Sendable ((hr: Int, rr: Int, events: Int, battery: Int,
                                    spo2: Int, skinTemp: Int, resp: Int, gravity: Int)) async -> Void
    let log: @Sendable (String) async -> Void
    let rejectedSink: @Sendable ([[UInt8]], UInt32, DeviceFamily) async -> Bool
    let onChunk: @Sendable (Bool, Bool) async -> Void
    let connectionActive: @Sendable () -> Bool
    let connectionLog: @Sendable (String) async -> Void
    let firmwareLayout: @Sendable (Int) async -> Void
    let onPersistCircuitBreak: @Sendable () async -> Void
    let onOffloadComplete: @Sendable () async -> Void
    var opticalSink: (@Sendable (String, [[UInt8]]) async -> Bool)? = nil
}

/// Serial offload pipeline: FIFO frame queue, chunk commits, and IMU session persistence off the main actor.
actor BackfillActor {
    private var backfiller: Backfiller?
    private var queue: [[UInt8]] = []
    private var draining = false
    private var onOffloadComplete: (() async -> Void)?

    func configure(store: BackfillStoreWriting,
                   deviceId: String,
                   hooks: BackfillMainHooks,
                   enableRawCapture: Bool,
                   postOffloadJobKinds: [String],
                   extract: @escaping Backfiller.Extractor = { extractHistoricalStreams($0, deviceClockRef: $1, wallClockRef: $2,
                                                                                         sessionOldestUnix: $3, sessionNewestUnix: $4,
                                                                                         subLagInterp: PuffinExperiment.ppgHrSubLagInterpEnabled) }) {
        onOffloadComplete = hooks.onOffloadComplete
        backfiller = Backfiller(
            store: store,
            deviceId: deviceId,
            ackTrim: { trim, endData in await hooks.ackTrim(trim, endData) },
            onBankedOffload: { counts in await hooks.onBankedOffload(counts) },
            enableRawCapture: enableRawCapture,
            log: { line in await hooks.log(line) },
            rejectedSink: { frames, trim, family in await hooks.rejectedSink(frames, trim, family) },
            imuSessionSink: { deviceId, records in
                return ImuSessionFileStore.shared.persistHistoricalImu(deviceId: deviceId, records: records)
            },
            opticalSink: hooks.opticalSink,
            onChunk: { decoded, console in await hooks.onChunk(decoded, console) },
            connectionActive: hooks.connectionActive,
            connectionLog: { line in await hooks.connectionLog(line) },
            firmwareLayout: { version in await hooks.firmwareLayout(version) },
            postOffloadJobKinds: postOffloadJobKinds,
            onPersistCircuitBreak: { await hooks.onPersistCircuitBreak() },
            extract: extract)
    }

    func setDeviceId(_ id: String) {
        backfiller?.deviceId = id
    }

    func setClockRef(_ ref: ClockRef?) {
        backfiller?.clockRef = ref
    }

    func setSessionOldestUnix(_ value: Int?) {
        backfiller?.sessionOldestUnix = value
    }

    func setSessionNewestUnix(_ value: Int?) {
        backfiller?.sessionNewestUnix = value
    }

    func begin(family: DeviceFamily, continuedAfterRows: Bool) {
        queue.removeAll(keepingCapacity: true)
        draining = false
        backfiller?.begin(family: family, continuedAfterRows: continuedAfterRows)
    }

    func enqueue(_ frame: [UInt8]) {
        queue.append(frame)
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    func timeoutFired() {
        backfiller?.timeoutFired()
        queue.removeAll(keepingCapacity: true)
        draining = false
    }

    func isBackfilling() async -> Bool {
        backfiller?.isBackfilling ?? false
    }

    func historyInFlight() -> Bool {
        draining || !queue.isEmpty || (backfiller?.isBackfilling ?? false)
    }

    func sessionSnapshot() -> BackfillSessionSnapshot? {
        guard let bf = backfiller else { return nil }
        return BackfillSessionSnapshot(
            sessionRowsPersisted: bf.sessionRowsPersisted,
            sessionMotionRows: bf.sessionMotionRows,
            sessionSkinTempRows: bf.sessionSkinTempRows,
            sessionNights: bf.sessionNights,
            sessionNightKeys: bf.sessionNightKeys,
            sessionClockDevice: bf.sessionClockDevice,
            sessionClockWall: bf.sessionClockWall,
            sessionUsedIdentityRef: bf.sessionUsedIdentityRef,
            sessionDroppedImplausible: bf.sessionDroppedImplausible,
            sessionDynAccel: bf.sessionDynAccel,
            persistStalled: bf.persistStalled,
            lastAckedTrim: bf.lastAckedTrim,
            family: bf.family,
            phaseSamples: bf.sessionPhaseTimingSamples(),
            rrEmissionLine: bf.sessionRrEmissionLine())
    }

    private func drain() async {
        guard let backfiller else { draining = false; return }
        while !queue.isEmpty {
            let frame = queue.removeFirst()
            await backfiller.ingest(frame)
            if !backfiller.isBackfilling {
                queue.removeAll(keepingCapacity: true)
                await onOffloadComplete?()
                draining = false
                return
            }
        }
        draining = false
    }
}
