import Foundation
import XCTest
import GRDB
import NoopPush
#if canImport(W2OwnerHarness)
@testable import W2OwnerHarness
#else
@testable import Strand
#endif

final class W2CaptureOwnerTests: XCTestCase {
    private let user = "11111111-1111-4111-8111-111111111111"
    private func scope() throws -> AccountScope { try .init(projectURL: "https://example.test", userID: user) }
    private func rejected(_ db: DatabaseQueue, _ scope: AccountScope) async {
        do { try await CloudPushCaptureBindings.validateOwner(db: db, scope: scope); XCTFail("Expected unbound capture") }
        catch { XCTAssertEqual(error as? AccountAuthError, .unboundCapture) }
    }

    func testMissingTableAndMissingRowRemainUnbound() async throws {
        let db = try DatabaseQueue()
        let expected = try scope()
        await rejected(db, expected)
        try await db.write { try $0.execute(sql:
            "CREATE TABLE localAccountOwner(singleton INTEGER PRIMARY KEY CHECK(singleton=1), projectURL TEXT, userID TEXT)") }
        await rejected(db, expected)
    }

    func testMatchingOwnerPassesAndForeignProjectOrUserFails() async throws {
        let db = try DatabaseQueue()
        let expected = try scope()
        try await db.write {
            try $0.execute(sql: "CREATE TABLE localAccountOwner(singleton INTEGER PRIMARY KEY, projectURL TEXT, userID TEXT)")
            try $0.execute(sql: "INSERT INTO localAccountOwner VALUES(1,?,?)", arguments: [expected.projectURL, expected.userID])
        }
        try await CloudPushCaptureBindings.validateOwner(db: db, scope: expected)
        await rejected(db, try .init(projectURL: "https://other.test", userID: user))
        await rejected(db, try .init(projectURL: expected.projectURL, userID: "22222222-2222-4222-8222-222222222222"))
    }

    func testWriterCannotBeReboundOrChangeSource() throws {
        let db = try DatabaseQueue()
        let expected = try scope()
        let source = "33333333-3333-4333-8333-333333333333"
        try CloudPushCaptureBindings.bind(db: db, scope: expected, sourceID: source)
        try CloudPushCaptureBindings.bind(db: db, scope: expected, sourceID: source)
        XCTAssertEqual(CloudPushCaptureBindings.binding(for: db)?.scope, expected)
        XCTAssertNil(CloudPushCaptureBindings.binding(for: try DatabaseQueue()))
        XCTAssertThrowsError(try CloudPushCaptureBindings.bind(db: db,
            scope: .init(projectURL: "https://other.test", userID: user), sourceID: source))
        XCTAssertThrowsError(try CloudPushCaptureBindings.bind(db: db, scope: expected, sourceID:
            "44444444-4444-4444-8444-444444444444"))
    }
}
