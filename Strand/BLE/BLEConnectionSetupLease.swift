import Foundation
#if os(iOS)
import UIKit
#endif

/// A single finite opportunity to finish discovery, authentication, and required subscriptions.
/// The deadline is app execution time, not a promise about OS scheduling. Expiration fences the
/// generation before releasing its assertion; it never starts a repeating reconnect timer.
@MainActor
final class BLEConnectionSetupLease {
    enum Failure: String { case deadline, assertionExpired, assertionDenied, backgroundWithoutAssertion }
    typealias Expiration = @MainActor @Sendable () -> Void
    typealias Cancel = () -> Void
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Cancel
    private var identifier: Int?
    private var cancelDeadline: Cancel?
    private var cancelBackgroundObservation: Cancel?
    private let end: (Int) -> Void
    private let failed: (Failure) -> Void
    private(set) var isFinished = false

    deinit {
        // Explicit lifecycle paths finish synchronously. This is only a last-resort owner
        // release; UIKit cleanup still belongs on the main actor if the owner is deallocated.
        let cancelDeadline = cancelDeadline, cancelObservation = cancelBackgroundObservation
        let identifier = identifier, end = end
        Task { @MainActor in
            cancelDeadline?()
            cancelObservation?()
            if let identifier { end(identifier) }
        }
    }

    init(seconds: TimeInterval = 20, begin: (@escaping Expiration) -> Int?,
         end: @escaping (Int) -> Void, schedule: Scheduler,
         foregroundFallback: ((@escaping () -> Void) -> Cancel)? = nil,
         failed: @escaping (Failure) -> Void) {
        self.end = end
        self.failed = failed
        let acquired = begin { [weak self] in self?.finish(failure: .assertionExpired) }
        if isFinished { if let acquired { end(acquired) }; return }
        identifier = acquired
        if acquired == nil {
            guard let foregroundFallback else { finish(failure: .assertionDenied); return }
            let cancel = foregroundFallback { [weak self] in self?.finish(failure: .backgroundWithoutAssertion) }
            if isFinished { cancel(); return }
            cancelBackgroundObservation = cancel
        }
        let cancel = schedule(seconds) { [weak self] in self?.finish(failure: .deadline) }
        if isFinished { cancel() } else { cancelDeadline = cancel }
    }

    func finish(failure: Failure? = nil) {
        guard !isFinished else { return }
        isFinished = true
        cancelDeadline?(); cancelDeadline = nil
        cancelBackgroundObservation?(); cancelBackgroundObservation = nil
        if let failure { failed(failure) }
        if let identifier { self.identifier = nil; end(identifier) }
    }

    static func acquire(failed: @escaping (Failure) -> Void) -> BLEConnectionSetupLease {
        let schedule: Scheduler = { seconds, deadline in
            let task = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled else { return }
                deadline()
            }
            return { task.cancel() }
        }
        #if os(iOS)
        let foregroundFallback: ((@escaping () -> Void) -> Cancel)? = UIApplication.shared.applicationState == .active ? { callback in
            let observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main) { _ in MainActor.assumeIsolated { callback() } }
            return { NotificationCenter.default.removeObserver(observer) }
        } : nil
        return BLEConnectionSetupLease(begin: { expired in
            let id = UIApplication.shared.beginBackgroundTask(withName: "BluetoothSetup") {
                MainActor.assumeIsolated { expired() }
            }
            return id == .invalid ? nil : id.rawValue
        }, end: { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: $0)) },
            schedule: schedule, foregroundFallback: foregroundFallback, failed: failed)
        #else
        // macOS has no UIKit assertion. The same finite deadline still owns this setup attempt.
        return BLEConnectionSetupLease(begin: { _ in 0 }, end: { _ in }, schedule: schedule, failed: failed)
        #endif
    }
}
