import Foundation
import Combine

/// Appearance-to-ready view state, not a rendered frame or a hardware display measurement.
@MainActor
final class ServerScoreContentReadyTrace: ObservableObject {
    struct Identity: Equatable {
        let generation: UUID?
        let day: String
        let timezone: String
    }
    typealias Completion = (SyncPipelineTrace.Outcome) -> Void
    private let begin: () -> Completion?
    private var completion: Completion?
    private var identity: Identity?
    private var visible = false

    init(begin: @escaping () -> Completion? = {
        let interval = SyncPipelineTrace.begin(.cachedContentReady)
        return { outcome in SyncPipelineTrace.end(interval, outcome: outcome) }
    }) {
        self.begin = begin
    }

    func appear(identity: Identity, ready: Bool) {
        visible = true
        restart(identity)
        if ready { finish(.succeeded) }
    }

    func update(identity: Identity, ready: Bool) {
        guard visible else { return }
        if identity != self.identity { restart(identity) }
        if ready { finish(.succeeded) }
    }

    func disappear() {
        visible = false
        finish(.cancelled)
        identity = nil
    }

    private func restart(_ identity: Identity) {
        finish(.cancelled)
        self.identity = identity
        completion = begin()
    }

    private func finish(_ outcome: SyncPipelineTrace.Outcome) {
        guard let completion else { return }
        defer { completion(outcome) }
        self.completion = nil
    }
}
