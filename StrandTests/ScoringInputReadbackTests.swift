import Foundation
import NoopPush
import XCTest
@testable import Strand

final class ScoringInputReadbackTests: XCTestCase {
    private let day = "2026-09-18"
    private func fixture() throws -> (AccountScope, ScoringInputChange, [String: Any]) {
        let scope = try AccountScope(projectURL: "https://input-read.invalid", userID: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        let change = try ScoringInputChange(device: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", kind: .profile,
            entity: "primary", effectiveDay: day, payload: Data("{}".utf8))
        return (scope, change, ["schemaVersion": 1, "userId": scope.userID, "sourceDeviceId": change.device,
            "kind": "profile", "entity": "primary", "headRevision": 50, "revision": 17,
            "effectiveDay": day, "deleted": false, "payload": ["schemaVersion": 1, "timezone": "UTC", "age": 30]])
    }
    private func read(_ body: [String: Any], scope: AccountScope, change: ScoringInputChange) throws -> ScoringInputValue {
        try .init(data: JSONSerialization.data(withJSONObject: body), scope: scope, change: change, asOfDay: day)
    }

    func testHeadAndEffectiveRevisionAreDistinctAndTombstoneRetainsIdentity() throws {
        let (scope, change, body) = try fixture()
        let value = try read(body, scope: scope, change: change)
        XCTAssertEqual(value.head.headRevision, 50); XCTAssertEqual(value.revision, 17)
        XCTAssertEqual(value.effectiveDay, day); XCTAssertNotNil(value.payload)
        var tombstone = body; tombstone["deleted"] = true; tombstone["payload"] = NSNull()
        let deleted = try read(tombstone, scope: scope, change: change)
        XCTAssertEqual(deleted.deleted, true); XCTAssertEqual(deleted.revision, 17); XCTAssertNil(deleted.payload)
    }

    func testFutureOnlyHeadDoesNotInventAnEffectivePayload() throws {
        let (scope, change, base) = try fixture()
        var body = base
        for key in ["revision", "effectiveDay", "deleted", "payload"] { body[key] = NSNull() }
        let value = try read(body, scope: scope, change: change)
        XCTAssertEqual(value.head.headRevision, 50); XCTAssertNil(value.revision); XCTAssertNil(value.payload)
        body.removeValue(forKey: "payload")
        XCTAssertThrowsError(try read(body, scope: scope, change: change))
    }

    func testWrongOwnerSourceEntityKindFutureOrMalformedRevisionCannotBePresented() throws {
        let (scope, change, base) = try fixture()
        let replacements: [(String, Any)] = [("userId", UUID().uuidString), ("sourceDeviceId", UUID().uuidString),
            ("entity", "other"), ("kind", "config"), ("schemaVersion", 2), ("headRevision", -1),
            ("revision", 51), ("revision", 0), ("revision", true), ("revision", 1.5),
            ("effectiveDay", "2026-09-19"), ("effectiveDay", "2026-02-30"),
            ("deleted", true), ("payload", NSNull())]
        for (key, value) in replacements {
            var body = base; body[key] = value
            XCTAssertThrowsError(try read(body, scope: scope, change: change), key)
        }
    }

    func testPayloadIsBoundedBeforePublication() throws {
        let (scope, change, base) = try fixture()
        var body = base; body["payload"] = ["large": String(repeating: "x", count: 65536)]
        XCTAssertThrowsError(try read(body, scope: scope, change: change))
    }
}
