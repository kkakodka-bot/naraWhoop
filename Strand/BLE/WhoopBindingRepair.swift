#if DEBUG
import Foundation
import GRDB
import WhoopStore

/// An explicit USB diagnostic launch can undo the legacy restoration bug without replacing the database.
/// Normal launches and Release builds never perform this repair.
enum WhoopBindingRepair {
    static func apply(store: WhoopStore, defaults: UserDefaults,
                      environment: [String: String]) throws -> Bool {
        guard let fromText = environment["NOOP_REPAIR_WHOOP_FROM"],
              let toText = environment["NOOP_REPAIR_WHOOP_TO"],
              let from = UUID(uuidString: fromText), let to = UUID(uuidString: toText), from != to,
              let targetKey = LastSyncAttribution.prefKey(peripheralId: to.uuidString),
              let oldKey = LastSyncAttribution.prefKey(peripheralId: from.uuidString),
              defaults.double(forKey: targetKey) > 0,
              defaults.object(forKey: oldKey) == nil else { return false }
        return try store.registryWriter.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pairedDevice") == 1 else { return false }
            try db.execute(sql: """
                UPDATE pairedDevice SET peripheralId = ?
                WHERE id = 'my-whoop' AND status = 'active' AND lower(brand) = 'whoop'
                  AND lower(peripheralId) = ?
                """, arguments: [to.uuidString, from.uuidString.lowercased()])
            return db.changesCount == 1
        }
    }
}
#endif
