#if os(iOS)
import BackgroundTasks
import GRDB
import Foundation

/// Best-effort BGAppRefresh continuation for cloud push when an offload leaves more rows than one run can send.
enum CloudPushBackgroundScheduler {
    private static var runHandler: (@Sendable () async -> Void)?

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
            let completion = CloudPushRefreshCompletion { success in refresh.setTaskCompleted(success: success) }
            refresh.expirationHandler = { completion.finish(success: false) }
            let work = Task {
                await CloudPushBackgroundRuntime.reconcileActive()
                await runHandler?()
                scheduleIfNeeded()
                completion.finish(success: !Task.isCancelled)
            }
            completion.attach(work)
        }
    }

    static func scheduleIfNeeded() {
        guard CloudPushSettings.ready else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancelScheduled() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }
}
#endif
