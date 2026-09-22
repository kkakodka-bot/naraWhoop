#if os(iOS)
import BackgroundTasks
import GRDB
import Foundation
import NoopPush

/// Best-effort BGAppRefresh continuation for cloud push when an offload leaves more rows than one run can send.
enum CloudPushBackgroundScheduler {
    private static var runHandler: (@Sendable () async -> Void)?
    @MainActor private static var scheduled: (AccountSessionContext, Date)?
    @MainActor private static var revision: UInt64 = 0

    private static var taskIdentifier: String {
        Bundle.main.bundleIdentifier.map { "\($0).cloudpush" } ?? "noop.cloudpush"
    }

    static func register(run: @escaping @Sendable () async -> Void) {
        runHandler = run
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let budgetOwner = UUID()
            ResourceBudget.shared.backgroundOpportunity(owner: budgetOwner, active: true)
            let completion = CloudPushRefreshCompletion { success in
                ResourceBudget.shared.backgroundOpportunity(owner: budgetOwner, active: false)
                refresh.setTaskCompleted(success: success)
            }
            refresh.expirationHandler = { completion.finish(success: false) }
            let work = Task {
                await MainActor.run { scheduled = nil }
                await CloudPushBackgroundRuntime.reconcileActive()
                await runHandler?()
                scheduleIfNeeded()
                completion.finish(success: !Task.isCancelled)
            }
            completion.attach(work)
        }
    }

    static func scheduleIfNeeded() {
        Task { @MainActor in
            revision &+= 1
            let capturedRevision = revision
            guard CloudPushSettings.ready, let (context, date) = await CloudPushBackgroundRuntime.nextWake(),
                  capturedRevision == revision, CloudAuthClient.isCurrent(context) else { return }
            guard let date else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
                scheduled = nil
                return
            }
            if let prior = scheduled, prior.0 == context, prior.1 == date { return }
            let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
            request.earliestBeginDate = date
            do { try BGTaskScheduler.shared.submit(request); scheduled = (context, date) }
            catch { scheduled = nil }
        }
    }

    static func cancelScheduled() {
        Task { @MainActor in
            revision &+= 1
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
            scheduled = nil
        }
    }
}
#endif
