import Foundation
import WhoopStore
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// Single orchestrator for post-offload work after strap data lands (#1538).
///
/// The strap→app offload (`Backfiller`) stays lossless and untouched. This engine owns what happens
/// AFTER rows are banked: re-score, cloud push, Apple Health write-back, and widget publish. Every
/// wake funnels through `drain(reason:)` so owed work is visible in `syncJob` and each pass is
/// recorded in `syncJournalEntry`.
@MainActor
final class SyncEngine {

    private weak var host: AppModel?
    /// Async actor methods are reentrant. Coalesce overlapping foreground/BG/offload wakes into one
    /// serial drain plus at most one trailing pass, so stage tokens cannot be churned by parallel loops.
    private var draining = false
    private var trailingDrainRequested = false

    init() {}

    func bind(_ host: AppModel) {
        self.host = host
    }

    /// Mark [kind] owed in the store. Returns the fresh token (#1681).
    @discardableResult
    func markOwed(_ kind: SyncJobKind, note: String? = nil) async -> String? {
        guard let store = await host?.repo.storeHandle() else { return nil }
        return try? await store.markJobOwed(kind: kind.rawValue, note: note)
    }

    /// Settle [kind] only when [token] still matches.
    func settle(_ kind: SyncJobKind, token: String?) async -> Bool {
        guard let token, !token.isEmpty,
              let store = await host?.repo.storeHandle() else { return false }
        return (try? await store.settleJob(kind: kind.rawValue, token: token)) ?? false
    }

    /// Whether any post-offload stage is still outstanding.
    func hasOwedWork() async -> Bool {
        await currentOwedKinds().isEmpty == false
    }

    /// The single entry point every wake calls.
    func drain(reason: SyncDrainPolicy.WakeReason) async {
        guard !draining else {
            trailingDrainRequested = true
            return
        }
        draining = true
        var passReason = reason
        repeat {
            trailingDrainRequested = false
            await drainOnce(reason: passReason)
            passReason = .bleEvent
        } while trailingDrainRequested
        draining = false
    }

    private func drainOnce(reason: SyncDrainPolicy.WakeReason) async {
        guard let host else { return }
        // Durable jobs may be visible after the first productive chunk, but export surfaces must describe
        // the terminal backlog, not an intermediate oldest-first slice. A disconnect clears this process-
        // local flag; the jobs remain in SQLite and the next wake resumes them.
        guard SyncDrainPolicy.shouldStartDrain(
            backlogBurstInProgress: host.live.postOffloadBurstInProgress) else { return }
        guard let store = await host.repo.storeHandle() else { return }

        await mirrorRescoreDebt(store: store)

        let owedRows = (try? await store.owedJobs()) ?? []
        let owedKinds = Set(owedRows.compactMap { SyncJobKind(rawValue: $0.kind) })
        let capturedTokens = Dictionary(uniqueKeysWithValues: owedRows.map { ($0.kind, $0.token) })

        let started = Date()
        var stagesRun: [SyncJobKind] = []
        var stagesFailed: [SyncJobKind] = []

        for stage in SyncDrainPolicy.stageOrder {
            guard SyncDrainPolicy.shouldRun(stage: stage, owedKinds: owedKinds, reason: reason),
                  let token = capturedTokens[stage.rawValue] else { continue }
            #if !os(iOS)
            if stage == .cloudPush || stage == .healthWriteback || stage == .widgetPublish { continue }
            #endif

            try? await store.recordJobAttempt(kind: stage.rawValue, token: token)
            let ok = await runStage(stage, token: token, reason: reason, host: host)
            if ok { stagesRun.append(stage) } else { stagesFailed.append(stage) }

            let rescoreStillOwed = ((try? await store.owedJobs()) ?? [])
                .contains { $0.kind == SyncJobKind.rescore.rawValue }
            guard SyncDrainPolicy.shouldContinue(
                after: stage, succeeded: ok, rescoreStillOwed: rescoreStillOwed) else {
                break
            }
        }

        let stillOwed = (try? await store.owedJobs()) ?? []
        let stillOwedKinds = stillOwed.map(\.kind)
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let note = stagesFailed.isEmpty
            ? nil
            : "failed: \(stagesFailed.map(\.rawValue).joined(separator: ","))"
        try? await store.appendSyncJournal(
            wakeReason: reason.rawValue,
            stagesRun: stagesRun.map(\.rawValue),
            stagesOwed: stillOwedKinds,
            durationMs: durationMs,
            note: note
        )
        host.live.syncStatusRevision &+= 1
    }

    // MARK: - Stage runners

    private func runStage(_ stage: SyncJobKind, token: String,
                          reason: SyncDrainPolicy.WakeReason,
                          host: AppModel) async -> Bool {
        switch stage {
        case .rescore:
            return await runRescore(token: token, reason: reason, host: host)
        case .cloudPush:
            return await runCloudPush(token: token, host: host)
        case .healthWriteback:
            return await runHealthWriteback(token: token, host: host)
        case .widgetPublish:
            return await runWidgetPublish(token: token, host: host)
        }
    }

    private func runRescore(token: String, reason: SyncDrainPolicy.WakeReason,
                            host: AppModel) async -> Bool {
        if ServerScoringSettings.skipsSyncCoupledRescore {
            ServerScoringSettings.settleSkippedLocalRescoreDebt()
            return await settle(.rescore, token: token)
        }
        switch reason {
        case .offloadComplete, .bleEvent, .stateRestoration:
            // CoreBluetooth may restore us for a short background wake. An owed
            // re-score can take minutes, so let the background policy defer it
            // instead of restarting the same pass on every restored launch.
            await RescoreBackgroundScheduler.run(log: { [live = host.live] line in
                live.append(log: line)
            }) {
                if RescoreBackgroundScheduler.isRescoreOwed {
                    await host.runDeferredRescoreIfOwed()
                } else {
                    await host.intelligence.analyzeRecent(skipIfUnchanged: true)
                }
            }
        default:
            if RescoreBackgroundScheduler.isRescoreOwed {
                await host.runDeferredRescoreIfOwed()
            } else {
                await RescoreBackgroundScheduler.run(log: { [live = host.live] line in
                    live.append(log: line)
                }) {
                    await host.intelligence.analyzeRecent(skipIfUnchanged: true)
                }
            }
        }

        // A productive chunk can re-mark rescore while this pass is running. Compare-token settle then
        // fails and blocks exports, leaving the newer generation for the trailing/next wake.
        return await Self.settleRescoreWhenReady(intelligence: host.intelligence) {
            await self.settle(.rescore, token: token)
        }
    }

    /// Admission starts before a pass has read its fingerprint or stamped legacy debt. A busy caller
    /// and a queued forced handoff must retain the SQLite job even while that legacy mark is absent.
    static func settleRescoreWhenReady(intelligence: IntelligenceEngine,
                                      settle: @MainActor () async -> Bool) async -> Bool {
        guard !intelligence.rescoreInProgress,
              !RescoreBackgroundScheduler.isRescoreOwed else { return false }
        return await settle()
    }

    private func runCloudPush(token: String, host: AppModel) async -> Bool {
        guard CloudPushSettings.ready else {
            return await settle(.cloudPush, token: token)
        }
        guard let writer = await host.repo.registryWriterForPush() else { return false }
        let outcome = await CloudPushWorker.runOnce(
            db: writer,
            trigger: "sync-engine",
            markOwed: { [weak self] in await self?.markOwed(.cloudPush) }
        )
        switch outcome {
        case .completed:
            return await settle(.cloudPush, token: token)
        case .deferred:
            return false
        case .terminalFailure:
            // The error is already persisted for the UI. Retrying an unrecoverable response on every wake
            // would create a zombie job, so settle exactly the generation that produced this attempt.
            _ = await settle(.cloudPush, token: token)
            return false
        }
    }

    private func runHealthWriteback(token: String, host: AppModel) async -> Bool {
        #if os(iOS)
        guard let healthWriteBack = host.healthWriteBack else { return false }
        let ok = await healthWriteBack()
        guard ok else { return false }
        return await settle(.healthWriteback, token: token)
        #else
        return true
        #endif
    }

    private func runWidgetPublish(token: String, host: AppModel) async -> Bool {
        #if os(iOS)
        await WidgetSnapshot.publish(from: host)
        return await settle(.widgetPublish, token: token)
        #else
        return true
        #endif
    }

    // MARK: - Rescore mirror

    /// Mirror an in-flight/deferred legacy rescore mark into `syncJob`. Absence of that UserDefaults mark
    /// must not clear a row stamped by a productive history chunk; the database row is now the earlier,
    /// durable source of truth for work that has not started yet.
    private func mirrorRescoreDebt(store: WhoopStore) async {
        if RescoreBackgroundScheduler.isRescoreOwed,
           let token = RescoreBackgroundScheduler.currentOwedToken {
            try? await store.mirrorRescoreJob(token: token)
        }
    }

    private func currentOwedKinds() async -> Set<SyncJobKind> {
        guard let store = await host?.repo.storeHandle() else { return [] }
        await mirrorRescoreDebt(store: store)
        let rows = (try? await store.owedJobs()) ?? []
        return Set(rows.compactMap { SyncJobKind(rawValue: $0.kind) })
    }
}

#if os(iOS)
/// BGProcessing backstop that drains every owed post-offload stage when foreground/BLE wakes are not enough.
enum SyncMaintenanceBackgroundScheduler {

    private static var drainHandler: (@MainActor () async -> Void)?

    static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "com.noopapp.noop") + ".syncmaintenance"

    static func register(drain: @escaping @MainActor () async -> Void) {
        drainHandler = drain
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                await drainHandler?()
                guard !Task.isCancelled else { return }
                if await SyncMaintenanceBackgroundScheduler.shouldRearm() {
                    schedule()
                }
                let stillOwed = await SyncMaintenanceBackgroundScheduler.shouldRearm()
                completion.finish(success: !stillOwed)
            }
            task.expirationHandler = {
                worker.cancel()
                schedule()
                completion.finish(success: false)
            }
        }
    }

    static func scheduleIfNeeded() {
        Task { @MainActor in
            guard await shouldRearm() else { return }
            schedule()
        }
    }

    @MainActor
    private static func shouldRearm() async -> Bool {
        guard let model = AppModel.shared else { return false }
        return await model.syncEngine.hasOwedWork()
    }

    static func schedule() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private final class TaskCompletionGuard: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var finished = false

        init(task: BGTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
        }
    }
}
#endif
