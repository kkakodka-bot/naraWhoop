import Foundation
import GRDB

/// A runtime may revoke publication synchronously without waiting for its detached work.
/// The SQLite commit hook rejects queued and already-running transactions after revocation.
/// A new runtime opens a new connection/fence; durable data is not erased or reassigned.
public final class StoreWriteFence: @unchecked Sendable {
    public enum Failure: Error, Equatable { case revoked }
    let id = UUID()
    private let lock = NSLock()
    private var valid = true

    public init() {}
    public var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    public func invalidate() { lock.lock(); valid = false; lock.unlock() }
    public func check() throws { if !isValid { throw Failure.revoked } }
}

private final class RuntimeCommitObserver: TransactionObserver {
    private let fence: StoreWriteFence
    init(_ fence: StoreWriteFence) { self.fence = fence }
    // Commit notification is unconditional; per-row notifications are unnecessary.
    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseWillCommit() throws { try fence.check() }
    func databaseDidCommit(_ db: Database) {}
    func databaseDidRollback(_ db: Database) {}
}

extension WhoopStore {
    public func fenceWrites(untilRevoked fence: StoreWriteFence) throws {
        try fence.check()
        guard installedWriteFences.insert(fence.id).inserted else { return }
        dbWriter.add(transactionObserver: RuntimeCommitObserver(fence), extent: .databaseLifetime)
        try fence.check()
    }
}
