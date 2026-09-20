import Foundation
import XCTest
@testable import NoopPush

final class AccountStorageLayoutTests: XCTestCase {
    func testAccountAndProjectSwitchRetainsOriginalPendingBytes() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let a = try AccountScope(projectURL: "https://a.example", userID: "11111111-1111-4111-8111-111111111111")
        let b = try AccountScope(projectURL: "https://a.example", userID: "22222222-2222-4222-8222-222222222222")
        let otherProject = try AccountScope(projectURL: "https://b.example", userID: a.userID)
        let original = AccountStorageLayout(baseDirectory: base, scope: a)
        try original.prepare()
        let pending = original.uploadDirectory.appendingPathComponent("pending.bin")
        let bytes = Data([0, 1, 2, 3])
        try bytes.write(to: pending, options: .atomic)
        for scope in [b, otherProject, nil] {
            let switched = AccountStorageLayout(baseDirectory: base, scope: scope)
            try switched.prepare()
            XCTAssertNotEqual(switched.directory, original.directory)
            XCTAssertNotEqual(switched.preferencesSuite, original.preferencesSuite)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: switched.uploadDirectory.appendingPathComponent("pending.bin").path))
            XCTAssertEqual(try Data(contentsOf: pending), bytes)
        }
        let reopened = AccountStorageLayout(baseDirectory: base, scope: a)
        XCTAssertEqual(try Data(contentsOf: reopened.uploadDirectory.appendingPathComponent("pending.bin")), bytes)
    }

    func testLegacyDatabaseRemainsUnassignedAndUntouched() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let legacy = base.appendingPathComponent("whoop.sqlite")
        let original = Data("preserved legacy fixture".utf8)
        try original.write(to: legacy)
        let scope = try AccountScope(projectURL: "https://a.example", userID: "11111111-1111-4111-8111-111111111111")
        let layout = AccountStorageLayout(baseDirectory: base, scope: scope)
        try layout.prepare()
        XCTAssertNotEqual(layout.databaseURL, legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.databaseURL.path))
        XCTAssertEqual(try Data(contentsOf: legacy), original)
    }
}
