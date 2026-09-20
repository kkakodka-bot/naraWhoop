import Foundation
import GRDB

public enum LocalAccountOwnershipError: Error, Equatable {
    case invalidIdentity, mismatchedOwner, unassignedExistingData
}

extension WhoopStore {
    static func installAccountOwnershipSchema(_ db: Database) throws {
        try db.create(table: "localAccountOwner") { t in
            t.column("singleton", .integer).primaryKey().check { $0 == 1 }
            t.column("projectURL", .text).notNull()
            t.column("userID", .text).notNull()
        }
    }

    /// A new account store may bind once; an unowned populated store requires explicit recovery.
    public func bindAccountOwner(projectURL: String, userID: String) async throws {
        guard UUID(uuidString: userID) != nil,
              let url = URL(string: projectURL), url.host != nil else {
            throw LocalAccountOwnershipError.invalidIdentity
        }
        try await dbWriter.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT projectURL, userID FROM localAccountOwner WHERE singleton = 1") {
                guard row["projectURL"] as String == projectURL,
                      row["userID"] as String == userID else {
                    throw LocalAccountOwnershipError.mismatchedOwner
                }
                return
            }
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_schema
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                """)
            let metadata = Set(["grdb_migrations", "device", "pairedDevice", "localAccountOwner"])
            for table in tables where !metadata.contains(table) {
                let identifier = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(identifier) LIMIT 1)") == true {
                    throw LocalAccountOwnershipError.unassignedExistingData
                }
            }
            try db.execute(sql: "INSERT INTO localAccountOwner (singleton, projectURL, userID) VALUES (1, ?, ?)",
                           arguments: [projectURL, userID])
        }
    }
}
