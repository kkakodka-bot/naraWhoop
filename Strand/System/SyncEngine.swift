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
    /// serial drain. A trailing request gets a later eligible wake, not another page budget here.
    private var draining = false
    private var trailingDrainRequested = false

    /// Captures one complete evaluation and one export token. This is a revocable admission
    /// check, not an external-write receipt or an ordinary SQLite transaction fence.
    @MainActor
    final class DependentStageAdmission {
        private let current: () -> Bool
        private let revalidate: () async -> Bool
        private let settleCaptured: () async -> Bool
        private nonisolated let boundaryCheck: @Sendable () throws -> Void

        /// Production uses captureAdmission's captured Engine authority. Transport/queue tests may
        /// supply fixture-owned closures; this initializer does not confer Store or delivery proof.
        init(current: @escaping () -> Bool, revalidate: @escaping () async -> Bool,
             boundaryCheck: @escaping @Sendable () throws -> Void,
             settleCaptured: @escaping () async -> Bool) {
            self.current = current
            self.revalidate = revalidate
            self.boundaryCheck = boundaryCheck
            self.settleCaptured = settleCaptured
        }

        var isCurrent: Bool { !Task.isCancelled && current() }

        func validate() async -> Bool {
            guard isCurrent, await revalidate() else { return false }
            return isCurrent
        }

        nonisolated func checkBoundary() throws { try boundaryCheck() }

        fileprivate func settle() async -> Bool {
            guard await validate() else { return false }
            return await settleCaptured()
        }
    }

    /// A per-instance stage implementation; nil keeps the platform's live implementation.
    /// Synthetic sinks use the same attempt/admission/settlement path on macOS.
    struct DependentStageDriver {
        var afterAttempt: ((SyncJobKind) async -> Void)? = nil
        var perform: (SyncJobKind, DependentStageAdmission) async -> Bool
    }
    var dependentStageDriver: DependentStageDriver?

    init() {}

    func bind(_ host: AppModel) {
        self.host = host
    }

    func shutdownForAccountChange() {
        host = nil
        trailingDrainRequested = false
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

    /// Held jobs stay visible in owedJobs, but their presence is not an automatic retry request.
    func hasRunnableWork() async -> Bool {
        guard let host, host.isAccountRuntimeActive,
              let store = await host.repo.storeHandle(), host.isAccountRuntimeActive else { return false }
        do {
            let rows = try await store.owedJobs()
            guard !rows.isEmpty else { return false }
            if rows.contains(where: { $0.kind == SyncJobKind.cloudPush.rawValue }) { return true }
            let state = await host.intelligence.preparePreferenceProjection()
            guard host.isAccountRuntimeActive else { return false }
            return state == .complete || state.hasRunnableWork(at: Int64(Date().timeIntervalSince1970))
        } catch { return false }
    }

    /// The single entry point every wake calls.
    func drain(reason: SyncDrainPolicy.WakeReason) async {
        guard !draining else {
            trailingDrainRequested = true
            return
        }
        draining = true
        trailingDrainRequested = false
        await drainOnce(reason: reason)
        draining = false
        if trailingDrainRequested {
            trailingDrainRequested = false
            #if os(iOS)
            SyncMaintenanceBackgroundScheduler.scheduleIfNeeded()
            #endif
        }
    }

    private func drainOnce(reason: SyncDrainPolicy.WakeReason) async {
        guard ResourceBudget.shared.permits(.bulk) else { return }
        guard let host, host.isAccountRuntimeActive else { return }
        guard let store = await host.repo.storeHandle() else { return }
        await drainRawUpload(store: store, host: host, reason: reason)
        guard host.isAccountRuntimeActive, !Task.isCancelled else { return }
        // Durable jobs may be visible after the first productive chunk, but export surfaces must describe
        // the terminal backlog, not an intermediate oldest-first slice. A disconnect clears this process-
        // local flag; the jobs remain in SQLite and the next wake resumes them.
        guard SyncDrainPolicy.shouldStartDrain(
            backlogBurstInProgress: host.live.postOffloadBurstInProgress) else { return }

        await mirrorRescoreDebt(store: store)

        guard let owedRows = try? await store.owedJobs(), host.isAccountRuntimeActive,
              !Task.isCancelled else { return }
        let owedKinds = Set(owedRows.compactMap { SyncJobKind(rawValue: $0.kind) })
        let capturedTokens = Dictionary(uniqueKeysWithValues: owedRows.map { ($0.kind, $0.token) })

        let started = Date()
        var stagesRun: [SyncJobKind] = []
        var stagesFailed: [SyncJobKind] = []
        var stagesHeld: [SyncJobKind] = []
        var prerequisiteInvoked = false

        for stage in SyncDrainPolicy.stageOrder {
            if stage == .cloudPush { continue }
            guard ResourceBudget.shared.permits(.bulk) else { break }
            guard host.isAccountRuntimeActive, !Task.isCancelled else { return }
            guard SyncDrainPolicy.shouldRun(stage: stage, owedKinds: owedKinds, reason: reason),
                  let token = capturedTokens[stage.rawValue] else { continue }
            #if !os(iOS)
            if stage != .rescore && dependentStageDriver == nil { continue }
            #endif

            var admission: DependentStageAdmission?
            if stage != .rescore {
                var state = await host.intelligence.preparePreferenceProjection()
                guard host.isAccountRuntimeActive, !Task.isCancelled else { return }
                if !owedKinds.contains(.rescore), !prerequisiteInvoked,
                   state.hasRunnableWork(at: Int64(Date().timeIntervalSince1970)) {
                    prerequisiteInvoked = true
                    await RescoreBackgroundScheduler.run(projection: state,
                        log: { [live = host.live] in live.append(log: $0) }) {
                        state = await host.intelligence.runPreferenceProjection()
                    }
                }
                // The barrier also applies when no rescore row was present in the captured list.
                guard state == .complete else { stagesHeld.append(stage); break }
                guard let captured = await captureAdmission(stage: stage, token: token, store: store, host: host) else {
                    stagesHeld.append(stage); break
                }
                do { try await store.recordJobAttempt(kind: stage.rawValue, token: token) }
                catch { stagesFailed.append(stage); break }
                await dependentStageDriver?.afterAttempt?(stage)
                guard await captured.validate() else { stagesHeld.append(stage); break }
                admission = captured
            } else {
                prerequisiteInvoked = true
            }
            let outcome = await runStage(stage, token: token, reason: reason, host: host,
                                         admission: admission)
            let ok = outcome == .completed
            switch outcome {
            case .completed: stagesRun.append(stage)
            case .held: stagesHeld.append(stage)
            case .deferred: break
            case .failed: stagesFailed.append(stage)
            }

            guard let remaining = try? await store.owedJobs(), host.isAccountRuntimeActive,
                  !Task.isCancelled else { return }
            let rescoreStillOwed = remaining.contains { $0.kind == SyncJobKind.rescore.rawValue }
            guard SyncDrainPolicy.shouldContinue(
                after: stage, succeeded: ok, rescoreStillOwed: rescoreStillOwed) else {
                break
            }
        }

        guard let stillOwed = try? await store.owedJobs(), host.isAccountRuntimeActive,
              !Task.isCancelled else { return }
        let stillOwedKinds = stillOwed.map(\.kind)
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let messages = [
            stagesFailed.isEmpty ? nil : "failed: \(stagesFailed.map(\.rawValue).joined(separator: ","))",
            stagesHeld.isEmpty ? nil : "held: \(stagesHeld.map(\.rawValue).joined(separator: ",")); dependent exports retained"
        ].compactMap { $0 }
        let note = messages.isEmpty ? nil : messages.joined(separator: "; ")
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

    private enum StageOutcome { case completed, held, deferred, failed }

    /// Transport depends on the captured owner and debt token. Health/widget exports below
    /// still require their physiological projection, but cannot hold this raw lane.
    private func drainRawUpload(store: WhoopStore, host: AppModel,
                                reason: SyncDrainPolicy.WakeReason) async {
        guard let row = try? await store.owedJobs().first(where: { $0.kind == SyncJobKind.cloudPush.rawValue }),
              host.isAccountRuntimeActive, !Task.isCancelled else { return }
        let token = row.token
        let identity = CloudRuntimeIdentity.snapshot().context
        let admission = DependentStageAdmission(current: { [weak host] in
            host?.isAccountRuntimeActive == true && CloudRuntimeIdentity.snapshot().context == identity
        }, revalidate: { [weak host] in
            guard host?.isAccountRuntimeActive == true,
                  let rows = try? await store.owedJobs() else { return false }
            return rows.contains { $0.kind == SyncJobKind.cloudPush.rawValue && $0.token == token }
        }, boundaryCheck: {
            guard CloudRuntimeIdentity.snapshot().context == identity else { throw CocoaError(.userCancelled) }
        }, settleCaptured: { [weak host] in
            guard host?.isAccountRuntimeActive == true else { return false }
            return (try? await store.settleJob(kind: SyncJobKind.cloudPush.rawValue, token: token)) ?? false
        })
        guard await admission.validate() else { return }
        do { try await store.recordJobAttempt(kind: SyncJobKind.cloudPush.rawValue, token: token) }
        catch { return }
        await dependentStageDriver?.afterAttempt?(.cloudPush)
        guard await admission.validate() else { return }
        let started = Date()
        let outcome = await runStage(.cloudPush, token: token, reason: reason, host: host, admission: admission)
        guard host.isAccountRuntimeActive else { return }
        let remaining = (try? await store.owedJobs()) ?? []
        try? await store.appendSyncJournal(wakeReason: reason.rawValue,
            stagesRun: outcome == .completed ? [SyncJobKind.cloudPush.rawValue] : [],
            stagesOwed: remaining.map(\.kind), durationMs: Int(Date().timeIntervalSince(started) * 1_000),
            note: "raw transport: \(outcome)")
        host.live.syncStatusRevision &+= 1
    }

    private func captureAdmission(stage: SyncJobKind, token: String, store: WhoopStore,
                                  host: AppModel) async -> DependentStageAdmission? {
        guard let captured = await host.intelligence.capturePreferenceExportAdmission(expectedStore: store),
              host.isAccountRuntimeActive, !Task.isCancelled else { return nil }
        let admission = DependentStageAdmission(current: { [weak host] in
            guard let host, host.isAccountRuntimeActive else { return false }
            return host.intelligence.isPreferenceExportAdmissionCurrent(captured)
        }, revalidate: { [weak host] in
            guard let host, host.isAccountRuntimeActive,
                  await host.intelligence.validatePreferenceExportAdmission(captured),
                  let rows = try? await store.owedJobs() else { return false }
            return !rows.contains { $0.kind == SyncJobKind.rescore.rawValue }
                && rows.contains { $0.kind == stage.rawValue && $0.token == token }
        }, boundaryCheck: host.intelligence.preferenceExportBoundaryCheck(captured),
           settleCaptured: { [weak host] in
            guard let host, host.isAccountRuntimeActive else { return false }
            return await host.intelligence.settlePreferenceDependentJob(kind: stage,
                capturedToken: token, admission: captured)
        })
        return await admission.validate() ? admission : nil
    }

    private func runStage(_ stage: SyncJobKind, token: String,
                          reason: SyncDrainPolicy.WakeReason,
                          host: AppModel,
                          admission: DependentStageAdmission?) async -> StageOutcome {
        if stage != .rescore {
            guard let admission, await admission.validate() else { return .held }
            if let driver = dependentStageDriver {
                guard await driver.perform(stage, admission) else { return .failed }
                return await admission.settle() ? .completed : .held
            }
        }
        switch stage {
        case .rescore:
            return await runRescore(token: token, reason: reason, host: host)
        case .cloudPush:
            guard let admission else { return .held }
            return await runCloudPush(host: host, admission: admission) ? .completed : .failed
        case .healthWriteback:
            guard let admission else { return .held }
            return await runHealthWriteback(host: host, admission: admission) ? .completed : .failed
        case .widgetPublish:
            guard let admission else { return .held }
            return await runWidgetPublish(host: host, admission: admission) ? .completed : .failed
        }
    }

    private func runRescore(token: String, reason: SyncDrainPolicy.WakeReason,
                            host: AppModel) async -> StageOutcome {
        if ServerScoringSettings.skipsSyncCoupledRescore {
            ServerScoringSettings.settleSkippedLocalRescoreDebt()
            return await settle(.rescore, token: token) ? .completed : .held
        }
        var state = await host.intelligence.preparePreferenceProjection()
        guard host.isAccountRuntimeActive else { return .deferred }
        if state.hasRunnableWork(at: Int64(Date().timeIntervalSince1970)) {
            guard let store = await host.repo.storeHandle(), host.isAccountRuntimeActive else { return .deferred }
            do { try await store.recordJobAttempt(kind: SyncJobKind.rescore.rawValue, token: token) }
            catch { return .failed }
            await RescoreBackgroundScheduler.run(projection: state, log: { [live = host.live] in live.append(log: $0) }) {
                state = await host.intelligence.runPreferenceProjection()
            }
        }
        guard host.isAccountRuntimeActive else { return .deferred }
        if state == .complete {
            return await host.intelligence.settlePreferenceRescoreJob(capturedToken: token) ? .completed : .deferred
        }
        switch state {
        case .evaluatedPartial, .held: return .held
        default: return .deferred
        }
    }

    /// Admission starts before a pass has read its fingerprint or stamped legacy debt. A busy caller
    /// and a queued forced handoff must retain the SQLite job even while that legacy mark is absent.
    static func settleRescoreWhenReady(intelligence: IntelligenceEngine,
                                      settle: @MainActor () async -> Bool) async -> Bool {
        guard !intelligence.rescoreInProgress,
              await intelligence.preparePreferenceProjection() == .complete else { return false }
        return await settle()
    }

    private func runCloudPush(host: AppModel,
                              admission: DependentStageAdmission) async -> Bool {
        guard CloudPushSettings.ready else {
            return await admission.settle()
        }
        guard let writer = await host.repo.registryWriterForPush() else { return false }
        guard await admission.validate() else { return false }
        let outcome = await CloudPushWorker.runOnce(
            db: writer,
            trigger: "sync-engine",
            markOwed: { [weak self] in await self?.markOwed(.cloudPush) },
            dependentAdmission: admission
        )
        switch outcome {
        case .completed:
            return await admission.settle()
        case .deferred:
            return false
        case .terminalFailure:
            // The error is already persisted for the UI. Retrying an unrecoverable response on every wake
            // would create a zombie job, so settle exactly the generation that produced this attempt.
            _ = await admission.settle()
            return false
        }
    }

    private func runHealthWriteback(host: AppModel,
                                    admission: DependentStageAdmission) async -> Bool {
        #if os(iOS)
        guard let healthWriteBack = host.healthWriteBack else { return false }
        guard await admission.validate() else { return false }
        let ok = await healthWriteBack(admission)
        guard ok else { return false }
        return await admission.settle()
        #else
        return true
        #endif
    }

    private func runWidgetPublish(host: AppModel,
                                 admission: DependentStageAdmission) async -> Bool {
        #if os(iOS)
        guard await admission.validate() else { return false }
        guard await WidgetSnapshot.publish(from: host, dependentAdmission: admission) else { return false }
        return await admission.settle()
        #else
        return true
        #endif
    }

    // MARK: - Rescore mirror

    /// Mirror an in-flight/deferred legacy rescore mark into `syncJob`. Absence of that UserDefaults mark
    /// must not clear a row stamped by a productive history chunk; the database row is now the earlier,
    /// durable source of truth for work that has not started yet.
    private func mirrorRescoreDebt(store: WhoopStore) async {
        // Account-scoped WPE uses the real SQLite token; a stale global legacy token cannot replace it.
        guard host?.accountContext == nil else { return }
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
                let stillOwed = await AppModel.shared?.syncEngine.hasOwedWork() ?? true
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
        // Pressure holds are not settled debt. Keep an OS-owned opportunity without starting
        // projection preparation during the very backlog/cooldown that deferred it.
        if !ResourceBudget.shared.permits(.bulk) { return await model.syncEngine.hasOwedWork() }
        return await model.syncEngine.hasRunnableWork()
    }

    static func schedule() {
        Task { @MainActor in
            guard await shouldRearm() else { return }
            submit()
        }
    }

    private static func submit() {
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
