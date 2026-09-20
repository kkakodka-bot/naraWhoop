import Foundation
import GRDB
import NoopPush

/// Result of one bounded cloud-push attempt. The orchestrator settles a captured token only for a
/// terminal outcome; busy/network/continuation exits keep the durable debt.
enum CloudPushRunOutcome: Equatable {
    case completed
    case deferred
    case terminalFailure
}

/// Runs one bounded cloud-push cycle after a successful offload or manual trigger.
enum CloudPushWorker {
    private static let maxDevicesPerRun = 4
    private static var isRunning = false

    static func enqueueAfterSuccessfulOffload(db: any DatabaseWriter) {
        guard CloudPushSettings.ready else { return }
        CloudPushSettings.recordPushStarted()
        Task { await runOnce(db: db, trigger: "offload") }
        #if os(iOS)
        CloudPushBackgroundScheduler.scheduleIfNeeded()
        #endif
    }

    static func runOnce(
        db: any DatabaseWriter,
        trigger: String,
        markOwed: (@Sendable () async -> Void)? = nil,
        settleOwed: (@Sendable () async -> Bool)? = nil
    ) async -> CloudPushRunOutcome {
        guard CloudPushSettings.enabledEndpoint() != nil else { return .completed }
        guard !isRunning else { return .deferred }
        isRunning = true
        defer { isRunning = false }

        #if os(iOS)
        if !CloudPushNetworkPolicy.isNetworkAvailable(wifiOnly: CloudPushSettings.wifiOnly) {
            CloudPushSettings.recordRetrying(
                message: String(localized: "Waiting for a network allowed by the Wi‑Fi only setting.")
            )
            await markOwed?()
            CloudPushBackgroundScheduler.scheduleIfNeeded()
            return .deferred
        }
        #endif

        guard let endpoint = CloudPushSettings.enabledEndpoint(),
              let token = CloudPushSettings.resolvedToken() else {
            CloudPushSettings.recordError(
                String(localized: "The saved token is unavailable. Save it again.")
            )
            return .terminalFailure
        }

        CloudPushSettings.recordRunning()

        let sourceId = CloudPushSettings.sourceId()
        let transport = CloudPushTransport(endpoint: endpoint, bearerToken: token)
        let capabilitiesResult = (try? await transport.capabilities()) ?? .rejected(
            reason: PushFailure(code: .networkIO).safeCode,
            retryable: true,
            failure: PushFailure(code: .networkIO)
        )
        guard case .available(let capabilities) = capabilitiesResult else {
            if case .rejected(_, let retryable, let failure) = capabilitiesResult {
                let message = CloudPushMessaging.pushFailureMessage(
                    failure ?? PushFailure(code: .capabilitiesInvalid)
                )
                if retryable {
                    CloudPushSettings.recordRetrying(message: message)
                    await markOwed?()
                    #if os(iOS)
                    CloudPushBackgroundScheduler.scheduleIfNeeded()
                    #endif
                } else {
                    CloudPushSettings.recordError(message)
                }
            }
            if case .rejected(_, let retryable, _) = capabilitiesResult {
                return retryable ? .deferred : .terminalFailure
            }
            return .terminalFailure
        }
        CloudPushSettings.recordCapabilities(endpoint: endpoint, capabilities: capabilities)
        let namespace = CloudPushSettings.progressNamespace(
            sourceId: sourceId,
            endpoint: endpoint,
            protocolVersion: capabilities.protocolVersion,
            receiverStateId: capabilities.receiverStateId
        )

        let imuPushSource = ImuSessionFileStore.shared as ImuSessionPushSource
        let eventPushSource = await MainActor.run {
            ExperimentEventLog.shared as any ExperimentEventPushSource
        }
        let snapshot = CloudPushSnapshot(
            db: db,
            imuPushSource: imuPushSource,
            eventPushSource: eventPushSource
        )
        let progress = CloudPushProgressStore(namespace: namespace)
        let startIndex = CloudPushSettings.nextDeviceIndex(namespace: namespace)
        let coordinator = PushCoordinator(
            source: snapshot,
            transport: transport,
            progress: progress,
            sourceId: sourceId,
            destinationStillCurrent: { CloudPushSettings.enabledEndpoint()?.url == endpoint.url }
        )
        let run = await coordinator.pushKnownDevices(
            startDeviceIndex: startIndex,
            maxDevices: maxDevicesPerRun,
            capabilities: capabilities,
            binaryEnabled: CloudPushSettings.binaryObjectsEnabled
        )

        CloudPushSettings.saveNextDeviceIndex(namespace: namespace, index: run.nextDeviceIndex)
        let cycleNeedsAnotherPass = CloudPushSettings.cycleNeedsAnotherPass(namespace: namespace)
            || run.hasMoreAppendRows
            || run.hasMoreBinaryRows
        let cycleCompleted = run.nextDeviceIndex == 0
        CloudPushSettings.saveCycleNeedsAnotherPass(
            namespace: namespace,
            needed: cycleCompleted ? false : cycleNeedsAnotherPass
        )

        if run.acceptedBatches > 0 {
            CloudPushSettings.recordAcceptedBatches(batches: run.acceptedBatches, records: run.acceptedRecords)
        }

        if run.hasRetryableFailure {
            CloudPushSettings.recordRetrying(
                message: CloudPushMessaging.pushFailureMessage(run.failure ?? PushFailure(code: .networkIO))
            )
            await markOwed?()
            #if os(iOS)
            CloudPushBackgroundScheduler.scheduleIfNeeded()
            #endif
            return .deferred
        }
        if run.rejectedBatches > 0 {
            CloudPushSettings.recordError(
                CloudPushMessaging.pushFailureMessage(run.failure ?? PushFailure(code: .httpClient))
            )
            return .terminalFailure
        }
        if !cycleCompleted || cycleNeedsAnotherPass {
            CloudPushSettings.recordContinuation()
            await markOwed?()
            #if os(iOS)
            CloudPushBackgroundScheduler.scheduleIfNeeded()
            #endif
            return .deferred
        }
        CloudPushSettings.recordSuccess()
        _ = await settleOwed?()
        return .completed
    }
}
