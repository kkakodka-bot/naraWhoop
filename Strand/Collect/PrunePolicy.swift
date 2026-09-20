import Foundation
/// Raw-outbox retention candidates. Neither age nor size alone permits deletion: WhoopStore
/// requires an exact, account-bound server receipt and elapsed retention grace. Unsent bytes
/// survive these targets; bounded quarantine admission fails closed if safe pruning cannot help.
enum PrunePolicy {
    static let keepWindowSeconds = 24 * 3600        // keep synced raw browsable ~24h
    static let maxUnsyncedBytes = 50 * 1024 * 1024  // soft footprint target, subject to receipt gate
}
