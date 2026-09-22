import GRDB
import WhoopProtocol

extension WhoopStore {
    /// Shared by RR reads and consumers whose cached/union reads must obey the same owner policy.
    public func isWhoop5RRSource(deviceId: String, unlabelledAliasOfWhoop5: Bool = false) async throws -> Bool {
        try syncRead { try Self.isWhoop5RRSource(db: $0, deviceId: deviceId,
                                              unlabelledAliasOfWhoop5: unlabelledAliasOfWhoop5) }
    }

    static func isWhoop5RRSource(db: Database, deviceId: String,
                               unlabelledAliasOfWhoop5: Bool = false) throws -> Bool {
        let row = try Row.fetchOne(db, sql: "SELECT model, brand FROM pairedDevice WHERE id = ?",
                                   arguments: [deviceId])
        let model: String? = row?["model"]
        let brand: String? = row?["brand"]
        // Only unknown identity needs wire evidence. Avoid scanning tagged rows for a known family.
        let knownFamily = DeviceFamily.confirmedRegistryFamily(model: model, brand: brand)
        let nonWhoop = brand.map { !$0.isEmpty && $0.lowercased() != "whoop" } ?? false
        var tagged = false
        if knownFamily == nil && !nonWhoop {
            tagged = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM rrInterval WHERE deviceId = ? AND srcChannel IN (5, 6, 7))
                """, arguments: [deviceId]) ?? false
            // Re-pairing can leave legacy rows under the canonical alias while callers still hold
            // that old ID. Resolve its active strap here so sleep edits and ordinary reads agree.
            // Physical owners and confirmed WHOOP 4 history never inherit another strap's policy.
            if !tagged && !unlabelledAliasOfWhoop5 && deviceId == "my-whoop",
               let active = try String.fetchOne(db, sql: "SELECT id FROM pairedDevice WHERE status = 'active' LIMIT 1"),
               active != deviceId {
                tagged = try isWhoop5RRSource(db: db, deviceId: active)
            }
        }
        return Whoop5RR.usesCanonicalSource(model: model, brand: brand, hasTaggedIntervals: tagged || unlabelledAliasOfWhoop5)
    }
}
