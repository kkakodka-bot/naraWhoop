import Foundation

/// Holds only retired capture writers, never their presentation tree or new credentials.
/// A failed final write must not release accepted bytes merely because the account changed.
@MainActor
final class RetiredCaptureDrain {
    private struct Entry {
        let id: UUID
        let drain: @MainActor () async -> Bool
    }
    private var entries: [Entry] = []
    private var running: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private let automaticRetry: Bool
    private let retryNanoseconds: UInt64
    var didChange: ((Int) -> Void)?
    var pendingCount: Int { entries.count }

    init(automaticRetry: Bool = true, retryNanoseconds: UInt64 = 30_000_000_000) {
        self.automaticRetry = automaticRetry
        self.retryNanoseconds = retryNanoseconds
    }

    func retain(id: UUID, drain: @escaping @MainActor () async -> Bool) {
        guard !entries.contains(where: { $0.id == id }) else { return }
        entries.append(.init(id: id, drain: drain))
        didChange?(entries.count)
        if automaticRetry { scheduleRetry(immediate: true) }
    }

    func retry() async {
        if let running { return await running.value }
        // Bound each pass and rotate failures so one unavailable store cannot starve other owners.
        let selected = Array(entries.prefix(16))
        guard !selected.isEmpty else { return }
        let task = Task { [weak self] in
            for entry in selected {
                let succeeded = await entry.drain()
                guard let self, let index = self.entries.firstIndex(where: { $0.id == entry.id }) else { continue }
                let retained = self.entries.remove(at: index)
                if !succeeded { self.entries.append(retained) }
                self.didChange?(self.entries.count)
            }
        }
        running = task
        await task.value
        running = nil
        if automaticRetry, !entries.isEmpty { scheduleRetry(immediate: false) }
    }

    private func scheduleRetry(immediate: Bool) {
        guard retryTimer == nil else { return }
        let delay = immediate ? 0 : retryNanoseconds
        retryTimer = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled, let self else { return }
            self.retryTimer = nil
            await self.retry()
        }
    }

    deinit { retryTimer?.cancel() }
}
