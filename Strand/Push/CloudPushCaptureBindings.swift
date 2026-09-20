import Foundation
import GRDB
import NoopPush

/// Root admits only writers opened at an AccountStorageLayout it owns. No legacy-store inference.
enum CloudPushCaptureBindings {
    struct Binding: Sendable {
        let scope: AccountScope
        let sourceID: String
        let imuSource: (any ImuSessionPushSource)?
    }
    private struct Entry {
        weak var writer: AnyObject?
        let binding: Binding
    }
    private static let lock = NSLock()
    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func bind(db: any DatabaseWriter, scope: AccountScope, sourceID: String,
                     imuSource: (any ImuSessionPushSource)? = nil) throws {
        guard UUID(uuidString: sourceID) != nil else { throw AccountAuthError.invalidIdentity }
        lock.lock(); defer { lock.unlock() }
        let object = db as AnyObject
        let key = ObjectIdentifier(object)
        if let entry = entries[key], entry.writer != nil {
            guard entry.binding.scope == scope, entry.binding.sourceID == sourceID else {
                throw AccountAuthError.unboundCapture
            }
            return
        }
        entries = entries.filter { $0.value.writer != nil }
        entries[key] = Entry(writer: object, binding: Binding(scope: scope, sourceID: sourceID, imuSource: imuSource))
    }

    static func binding(for db: any DatabaseWriter) -> Binding? {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(db as AnyObject)
        guard let entry = entries[key], entry.writer != nil else { return nil }
        return entry.binding
    }

    static func validateOwner(db: any DatabaseWriter, scope: AccountScope) async throws {
        let owner: AccountScope? = try await db.read { database in
            guard try database.tableExists("localAccountOwner"),
                  let row = try Row.fetchOne(database, sql: "SELECT projectURL, userID FROM localAccountOwner WHERE singleton = 1"),
                  let project: String = row["projectURL"], let user: String = row["userID"] else { return nil }
            return try? AccountScope(projectURL: project, userID: user)
        }
        guard owner == scope else { throw AccountAuthError.unboundCapture }
    }
}
