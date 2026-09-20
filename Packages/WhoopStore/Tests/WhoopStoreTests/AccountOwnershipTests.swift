import Foundation
import GRDB
import XCTest
@testable import WhoopStore

final class AccountOwnershipTests: XCTestCase {
    private let project = "https://account-owner.invalid"
    private let userA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let userB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    func testFreshStoreBindsOnceAndRejectsAnotherOwner() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.bindAccountOwner(projectURL: project, userID: userA)
        try await store.bindAccountOwner(projectURL: project, userID: userA)
        do {
            try await store.bindAccountOwner(projectURL: project, userID: userB)
            XCTFail("A writer must never be rebound to another user")
        } catch { XCTAssertEqual(error as? LocalAccountOwnershipError, .mismatchedOwner) }
    }

    func testPopulatedLegacyStoreRequiresExplicitRecoveryWithoutDeletingData() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO ppgWaveformSample(deviceId, ts, samples, recordIndex) VALUES('strap', 1, X'0102', 7)")
        }
        do {
            try await store.bindAccountOwner(projectURL: project, userID: userA)
            XCTFail("An unassigned capture is not evidence of account ownership")
        } catch { XCTAssertEqual(error as? LocalAccountOwnershipError, .unassignedExistingData) }
        let bytes = try await store.registryWriter.read { db in
            try Data.fetchOne(db, sql: "SELECT samples FROM ppgWaveformSample WHERE recordIndex = 7")
        }
        XCTAssertEqual(bytes, Data([1, 2]))
    }

    func testOwnerPersistsAcrossReopenAndProjectChangesAreRejected() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("owned.sqlite").path
        do {
            let original = try await WhoopStore(path: path)
            try await original.bindAccountOwner(projectURL: project, userID: userA)
        }
        let reopened = try await WhoopStore(path: path)
        try await reopened.bindAccountOwner(projectURL: project, userID: userA)
        do {
            try await reopened.bindAccountOwner(projectURL: "https://other-project.invalid", userID: userA)
            XCTFail("A user UUID on another project is a different owner")
        } catch { XCTAssertEqual(error as? LocalAccountOwnershipError, .mismatchedOwner) }
    }
}
