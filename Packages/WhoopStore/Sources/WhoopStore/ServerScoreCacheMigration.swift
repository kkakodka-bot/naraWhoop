import GRDB

/// The integration owner registers this additive migration after the existing v47 cache.
/// Legacy rows have no provable account ownership and are deliberately not copied.
public enum ServerScoreCacheMigration {
    public static let identifier = "v48-scoped-server-score-cache"

    public static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier, migrate: migrate)
    }

    public static func migrate(_ db: Database) throws {
        try db.create(table: "serverScoreSnapshotCache") { t in
            t.column("projectURL", .text).notNull()
            t.column("userID", .text).notNull()
            t.column("sourceDeviceID", .text).notNull()
            t.column("day", .text).notNull()
            t.column("timeZoneID", .text).notNull()
            t.column("schemaVersion", .integer).notNull()
            t.column("algorithmVersion", .text).notNull()
            t.column("inputRevision", .integer).notNull()
            t.column("resultRevision", .integer).notNull()
            t.column("state", .text).notNull()
            t.column("payload", .blob).notNull()
            t.column("fetchedAt", .double).notNull()
            t.column("accessedAt", .double).notNull()
            t.primaryKey(["projectURL", "userID", "sourceDeviceID", "day", "timeZoneID",
                          "schemaVersion", "algorithmVersion"])
        }
        try db.create(index: "serverScoreSnapshotCache_eviction", on: "serverScoreSnapshotCache",
                      columns: ["accessedAt", "resultRevision"])
    }
}
