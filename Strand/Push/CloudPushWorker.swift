import Foundation
import GRDB
import NoopPush

enum CloudPushRunOutcome: Equatable {
    case completed, deferred, terminalFailure
}

/// A captured writer binding is the only authority for choosing upload ownership.
enum CloudPushWorker {
    private static let maxDevicesPerRun = 4
    private static let runLock = NSLock()
    private static var isRunning = false

    private static func beginRun() -> Bool {
        runLock.lock(); defer { runLock.unlock() }
        guard !isRunning else { return false }
        isRunning = true
        return true
    }
    private static func endRun() {
        runLock.lock(); defer { runLock.unlock() }; isRunning = false
    }

    static func enqueueAfterSuccessfulOffload(db: any DatabaseWriter) {
        guard CloudPushSettings.ready, CloudPushCaptureBindings.binding(for: db) != nil else { return }
        Task { await runOnce(db: db, trigger: "offload") }
        #if os(iOS)
        CloudPushBackgroundScheduler.scheduleIfNeeded()
        #endif
    }

    static func runOnce(
        db: any DatabaseWriter,
        trigger: String,
        markOwed: (@Sendable () async -> Void)? = nil,
        settleOwed: (@Sendable () async -> Bool)? = nil,
        dependentAdmission: SyncEngine.DependentStageAdmission? = nil
    ) async -> CloudPushRunOutcome {
        var traceOutcome = SyncPipelineTrace.Outcome.pending
        defer { SyncPipelineTrace.event(.uploadScheduling, outcome: traceOutcome) }
        guard ResourceBudget.shared.permits(.bulk), let endpoint = CloudPushSettings.enabledEndpoint() else { return .deferred }
        guard let binding = CloudPushCaptureBindings.binding(for: db),
              let initial = CloudAuthClient.currentContext(), binding.scope == initial.scope else {
            traceOutcome = .authenticationRequired
            // Root must retain debt for the original/unassigned writer. No account is inferred here.
            return .deferred
        }
        if let credential = CloudEnrollment.currentCredential(sourceId: binding.sourceID) {
            guard credential.userId == initial.scope.userID,
                  CloudCaptureScope.isActive(for: credential.userId) else {
                CloudPushSettings.recordError(
                    String(localized: "This installation must be enrolled before export can run.")
                )
                return .terminalFailure
            }
        }
        guard beginRun() else { return .deferred }
        defer { endRun() }
        #if os(iOS)
        if !CloudPushNetworkPolicy.isNetworkAvailable(wifiOnly: CloudPushSettings.wifiOnly) {
            traceOutcome = CloudPushSettings.wifiOnly ? .waitingForWiFi : .offline
            return .deferred
        }
        #endif

        let authorization: AuthorizedCloudSession
        let admission: AccountPushAdmission
        let transport: AccountFencedTransport
        let accountTransport: CloudAccountPushTransport
        do {
            let interval = SyncPipelineTrace.begin(.uploadPreparation)
            var preparationOutcome = SyncPipelineTrace.Outcome.failed
            defer { SyncPipelineTrace.end(interval, outcome: preparationOutcome) }
            authorization = try await CloudAuthClient.authorizedSession()
            guard authorization.context == initial else { throw AccountAuthError.staleOperation }
            try await CloudPushCaptureBindings.validateOwner(db: db, scope: initial.scope)
            if let credential = CloudEnrollment.currentCredential(sourceId: binding.sourceID) {
                guard await CloudCaptureScope.verifyDatabase(db, ownerId: credential.userId) else {
                    throw AccountAuthError.unboundCapture
                }
            }
            guard await validate(dependentAdmission) else { throw CancellationError() }
            admission = try AccountPushAdmission(
                context: initial, captureScope: binding.scope, sourceID: binding.sourceID,
                isCurrent: { context in
                    CloudAuthClient.isCurrent(context) && CloudPushSettings.enabledEndpoint()?.url == endpoint.url
                }
            )
            accountTransport = try CloudAccountPushTransport(endpoint: endpoint, authorization: authorization,
                                                             dependentAdmission: dependentAdmission)
            accountTransport.base.requirePreparedSelections()
            transport = AccountFencedTransport(
                transport: accountTransport,
                admission: admission
            )
            preparationOutcome = .succeeded
        } catch let error as AccountAuthError {
            traceOutcome = error == .unboundCapture ? .pending :
                (error == .staleOperation ? .cancelled : .authenticationRequired)
            if error == .unboundCapture {
                CloudPushSettings.recordScopedRun(context: initial, state: .retrying,
                    message: "unboundCapture: upload is waiting for the captured database owner.")
            }
            return .deferred
        } catch is CancellationError {
            traceOutcome = .cancelled
            return .deferred
        } catch {
            traceOutcome = .failed
            return .deferred
        }
        CloudPushSettings.recordScopedRun(context: initial, state: .running)

        let capabilities: PushCapabilities
        do {
            let interval = SyncPipelineTrace.begin(.uploadPreparation)
            var preparationOutcome = SyncPipelineTrace.Outcome.failed
            defer { SyncPipelineTrace.end(interval, outcome: preparationOutcome) }
            let result = try await transport.capabilities()
            guard await validate(dependentAdmission) else { throw CancellationError() }
            try admission.check()
            switch result {
            case .available(let value):
                if let credential = CloudEnrollment.currentCredential(sourceId: binding.sourceID) {
                    if let advertisedUser = value.userId, advertisedUser != credential.userId {
                        CloudPushSettings.recordError(
                            String(localized: "The receiver identity does not match this installation's enrollment.")
                        )
                        return .terminalFailure
                    }
                    if let advertisedSource = value.sourceId, advertisedSource != credential.sourceId {
                        CloudPushSettings.recordError(
                            String(localized: "The receiver identity does not match this installation's enrollment.")
                        )
                        return .terminalFailure
                    }
                    CloudPushSettings.recordCapabilities(endpoint: endpoint, capabilities: value, credential: credential)
                }
                capabilities = value
            case .rejected(_, let retryable, let failure):
                traceOutcome = failure?.code == .httpAuth ? .authenticationRequired : .failed
                CloudPushSettings.recordScopedRun(context: initial, state: .retrying,
                    message: "Upload is waiting for an authenticated, available receiver.")
                return retryable || failure?.code == .httpAuth ? .deferred : .terminalFailure
            }
            try admission.check()
            preparationOutcome = .succeeded
        } catch is CancellationError {
            traceOutcome = .cancelled
            return .deferred
        } catch {
            traceOutcome = CloudAuthClient.isCurrent(initial) ? .failed : .cancelled
            return .deferred
        }

        let namespace = admission.namespace(endpoint: endpoint.url, protocolVersion: capabilities.protocolVersion,
                                             receiverStateID: capabilities.receiverStateId)
        let capturedSnapshot = CloudPushSnapshot(db: db, imuPushSource: binding.imuSource)
        let snapshot = AccountFencedSnapshot(source: capturedSnapshot, admission: admission)
        let coordinator: PushCoordinator
        let preparedBlocked: Bool
        do {
            let runtime = try CloudPushBackgroundRuntime.current(for: initial)
            let makeCommitter: (CloudPushProgressStore) -> CloudPushSourceCommitter = { progress in
                CloudPushSourceCommitter(progress: progress, check: { try admission.check() },
                    acknowledge: { try await capturedSnapshot.acknowledgeCommitted($0, scope: initial.scope) },
                    cleanup: { try await accountTransport.base.sourceCommitted(batchID: $0) },
                    didApply: { try admission.check(); try capturedSnapshot.sourceProgressApplied($0, scope: initial.scope) },
                    didCleanup: { try admission.check(); try capturedSnapshot.sourceCleanupCompleted($0, scope: initial.scope) },
                    cleanupPrepared: { try admission.check(); try await accountTransport.base.preparedSourceCommitted($0) },
                    retirePrepared: { try admission.check(); try await accountTransport.base.retireSelection($0) })
            }
            let makeCoordinator: (CloudPushProgressStore, String) -> PushCoordinator = { durable, version in
                let committer = makeCommitter(durable)
                return PushCoordinator(source: snapshot, transport: transport,
                    progress: AccountFencedProgress(progress: durable, admission: admission), sourceId: binding.sourceID,
                    destinationStillCurrent: { (try? admission.check()) != nil }, receiptOwner: initial.scope,
                    objectProtocolVersion: PushProtocol.isObjectVersion(version) ? version : PushProtocol.objectVersion,
                    associateReceipt: { batch, rows, receipt in
                        try admission.check()
                        let id = try await accountTransport.base.preparedSelectionID(batchID: batch.batchId, sourceID: binding.sourceID)
                        let saved = try await runtime.queue.preparedSelection(id, captured: initial)
                        try await capturedSnapshot.associateReceipt(batch: batch, rows: rows, receipt: receipt, scope: initial.scope)
                        try admission.check()
                        try await durable.associate(batch: batch, rows: rows, receipt: receipt, prepared: saved)
                    },
                    associateInlineReceipt: { batch, receipt in
                        try admission.check()
                        let id = try await accountTransport.base.preparedSelectionID(batchID: batch.batchId, sourceID: binding.sourceID)
                        let saved = try await runtime.queue.preparedSelection(id, captured: initial)
                        try await durable.associateInline(batch: batch, receipt: receipt, prepared: saved)
                    },
                    commitSource: { value in
                        try admission.check()
                        guard let batchID = value.batchIDs.first else { throw CloudUploadError.invalidReceipt }
                        let id = try await accountTransport.base.preparedSelectionID(batchID: batchID, sourceID: binding.sourceID)
                        try await committer.commit(value, preparedSelectionID: id)
                    },
                    prepareSelection: { try admission.check(); try await accountTransport.base.prepareSelection($0, progressVersion: version) },
                    allowsPreparation: { ResourceBudget.shared.permits(.bulk) })
            }
            _ = try await CloudPushProgressRecovery.recover(admission: admission,
                endpoint: endpoint.url, receiverStateID: capabilities.receiverStateId,
                currentVersion: capabilities.protocolVersion, directory: runtime.progressDirectory,
                committer: makeCommitter)
            preparedBlocked = try await CloudPushPreparedRecovery.recover(queue: runtime.queue, context: initial,
                sourceID: binding.sourceID, endpoint: endpoint.url, receiverStateID: capabilities.receiverStateId,
                directory: runtime.progressDirectory, coordinator: makeCoordinator)
            guard await validate(dependentAdmission) else { throw CancellationError() }
            try admission.check()
            // Recovery may have changed the current namespace through a separately opened actor.
            // Reopen it before fresh selection rather than retaining a stale in-memory cursor.
            let refreshed = try CloudPushProgressStore(namespace: namespace, directory: runtime.progressDirectory,
                auxiliaryIdentityV2: capabilities.protocolVersion == PushProtocol.auxiliaryIdentityVersion)
            coordinator = makeCoordinator(refreshed, capabilities.protocolVersion)
        } catch is CancellationError { traceOutcome = .cancelled; return .deferred }
        catch { traceOutcome = .failed; return .deferred }
        let run = await coordinator.pushKnownDevices(
            startDeviceIndex: CloudPushSettings.nextDeviceIndex(namespace: namespace),
            maxDevices: maxDevicesPerRun, capabilities: capabilities,
            binaryEnabled: CloudPushSettings.binaryObjectsEnabled
        )
        guard await validate(dependentAdmission), (try? admission.check()) != nil else {
            traceOutcome = .cancelled; return .deferred
        }
        if !run.hasRetryableFailure && !preparedBlocked {
            CloudPushSettings.saveNextDeviceIndex(namespace: namespace, index: run.nextDeviceIndex)
        }
        let more = CloudPushSettings.cycleNeedsAnotherPass(namespace: namespace) ||
            run.hasMoreAppendRows || run.hasMoreBinaryRows
        let cycleCompleted = run.nextDeviceIndex == 0
        CloudPushSettings.saveCycleNeedsAnotherPass(namespace: namespace, needed: cycleCompleted ? false : more)

        if let runtime = try? CloudPushBackgroundRuntime.current(for: initial),
           let message = try? await runtime.queue.pausedMessage(captured: initial) {
            CloudPushSettings.recordScopedRun(context: initial, state: .failed,
                message: message, batches: run.acceptedBatches, records: run.acceptedRecords)
            if (try? admission.check()) != nil { await markOwed?() }
            return .terminalFailure
        }
        if run.hasRetryableFailure || preparedBlocked {
            traceOutcome = .failed
            CloudPushSettings.recordScopedRun(context: initial, state: .retrying,
                message: "Upload will retry.", batches: run.acceptedBatches, records: run.acceptedRecords)
            if (try? admission.check()) != nil { await markOwed?() }
            return .deferred
        }
        if run.rejectedBatches > 0 {
            traceOutcome = .failed
            CloudPushSettings.recordScopedRun(context: initial, state: .failed,
                message: "Upload requires attention.", batches: run.acceptedBatches, records: run.acceptedRecords)
            return .terminalFailure
        }
        if !cycleCompleted || more {
            CloudPushSettings.recordScopedRun(context: initial, state: .continuing,
                batches: run.acceptedBatches, records: run.acceptedRecords)
            if (try? admission.check()) != nil { await markOwed?() }
            #if os(iOS)
            CloudPushBackgroundScheduler.scheduleIfNeeded()
            #endif
            return .deferred
        }
        guard (try? admission.check()) != nil else { traceOutcome = .cancelled; return .deferred }
        // Legacy receipt replay is not proof of the current preference evaluation. A guarded
        // caller settles separately through SyncEngine's captured, permit-fenced transaction.
        // The legacy callback remains unchanged for callers without dependent admission.
        if dependentAdmission == nil { _ = await settleOwed?() }
        guard await validate(dependentAdmission), (try? admission.check()) != nil else {
            traceOutcome = .cancelled; return .deferred
        }
        CloudPushSettings.recordScopedRun(context: initial, state: .complete,
            batches: run.acceptedBatches, records: run.acceptedRecords)
        traceOutcome = .succeeded
        return .completed
    }

    private static func validate(_ admission: SyncEngine.DependentStageAdmission?) async -> Bool {
        guard ResourceBudget.shared.permits(.bulk) else { return false }
        guard let admission else { return true }
        guard await admission.validate() else { return false }
        do { try admission.checkBoundary(); return true }
        catch { return false }
    }
}
