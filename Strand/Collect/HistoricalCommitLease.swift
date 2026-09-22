import Foundation
#if os(iOS)
import UIKit
#endif

/// A finite completion assertion. Expiration fences delivery before releasing the OS assertion.
@MainActor
final class HistoricalCommitLease {
    private var identifier: Int?
    private var finished = false
    private let end: (Int) -> Void
    private let expired: () -> Void

    init(begin: (@escaping () -> Void) -> Int?, end: @escaping (Int) -> Void,
         expired: @escaping () -> Void) {
        self.end = end
        self.expired = expired
        let acquired = begin { [weak self] in self?.finish(expiring: true) }
        // A test adapter (or acquisition failure) may finish before begin returns its identifier.
        if finished { if let acquired { end(acquired) } }
        else if let acquired { identifier = acquired }
        else { finish(expiring: true) }
    }

    func finish(expiring: Bool = false) {
        guard !finished else { return }
        finished = true
        if expiring { expired() }
        if let identifier { self.identifier = nil; end(identifier) }
    }

    static func acquire(expired: @escaping () -> Void) -> HistoricalCommitLease {
        #if os(iOS)
        return HistoricalCommitLease(begin: { callback in
            let id = UIApplication.shared.beginBackgroundTask(withName: "HistoricalChunk", expirationHandler: callback)
            return id == .invalid ? nil : id.rawValue
        }, end: { UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: $0)) }, expired: expired)
        #else
        return HistoricalCommitLease(begin: { _ in 0 }, end: { _ in }, expired: expired)
        #endif
    }
}
