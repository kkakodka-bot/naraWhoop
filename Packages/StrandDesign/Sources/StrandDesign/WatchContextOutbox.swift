import Foundation

/// Latest-state delivery, including empty account-reset contexts, survives delayed activation.
/// The phone persists the snapshot separately; this is a bounded one-item in-process retry slot.
public struct WatchContextOutbox {
    public private(set) var pending: Data?
    public init() {}
    public mutating func enqueue(_ data: Data) { pending = data }
    @discardableResult
    public mutating func flush(activated: Bool, send: (Data) throws -> Void) -> Bool {
        guard activated, let pending else { return false }
        do {
            try send(pending)
            self.pending = nil
            return true
        } catch {
            return false
        }
    }
}
