import XCTest
import GRDB
import WhoopStore
import NoopPush
@testable import Strand

final class CloudCaptureScopeTests: XCTestCase {
    func testEnrolledStoreUpgradeRequiresExactOwnerAndSourceAndPreservesSamples() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = try AccountScope(projectURL: "https://example.test", userID: ownerA)
        try await CloudCaptureScope.prepareStore(store.registryWriter, legacyPath: nil, ownerId: ownerA, sourceId: sourceA)
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('my-whoop',100,65)")
        }
        do {
            try await CloudCaptureScope.bindEnrolledOwner(store.registryWriter, scope: scope, ownerId: ownerA, sourceId: sourceB)
            XCTFail("Wrong installation must not bind the store")
        } catch CloudCaptureScope.ScopeError.ownerMismatch { }
        try await CloudCaptureScope.bindEnrolledOwner(store.registryWriter, scope: scope, ownerId: ownerA, sourceId: sourceA)
        try await store.bindAccountOwner(projectURL: scope.projectURL, userID: scope.userID)
        let count = try await store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM hrSample") }
        XCTAssertEqual(count, 1)
        let other = try AccountScope(projectURL: "https://other.test", userID: ownerA)
        do {
            try await CloudCaptureScope.bindEnrolledOwner(store.registryWriter, scope: other, ownerId: ownerA, sourceId: sourceA)
            XCTFail("Existing endpoint ownership must remain fixed")
        } catch CloudCaptureScope.ScopeError.ownerMismatch { }
    }
    private let ownerA = "11111111-1111-4111-8111-111111111111"
    private let ownerB = "22222222-2222-4222-8222-222222222222"
    private let sourceA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let sourceB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    func testUnavailableCredentialDoesNotPinUnownedScopeAndRecoveryNeverRetargets() {
        let pin = CloudCaptureScope.Pin()
        XCTAssertNil(pin.resolve(nil))
        let first = CloudCaptureScope.Identity(ownerId: ownerA, sourceId: sourceA)
        XCTAssertEqual(pin.resolve(first), first)
        XCTAssertEqual(pin.resolve(nil), first)
        XCTAssertEqual(pin.resolve(.init(ownerId: ownerB, sourceId: sourceB)), first)
    }

    func testPathsSeparateOwnersInstallationsAndLegacyStorage() {
        let paths = [
            CloudCaptureScope.component("OpenWhoop", ownerId: ownerA, sourceId: sourceA),
            CloudCaptureScope.component("OpenWhoop", ownerId: ownerB, sourceId: sourceA),
            CloudCaptureScope.component("OpenWhoop", ownerId: ownerA, sourceId: sourceB),
            CloudCaptureScope.component("OpenWhoop", ownerId: nil, sourceId: sourceA),
            "OpenWhoop",
        ]
        XCTAssertEqual(Set(paths).count, paths.count)
        XCTAssertFalse(CloudCaptureScope.component("RawImu", ownerId: "../unsafe", sourceId: sourceA).contains(".."))
    }

    func testUpgradeCopiesPairingOnlyAndLeavesOriginalSamplesUntouched() async throws {
        let directory = (ProcessInfo.processInfo.environment["NARA_TEST_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldPath = directory.appendingPathComponent("legacy.sqlite").path
        let legacy = try await WhoopStore(path: oldPath)
        try await legacy.registryWriter.write { db in
            try db.execute(sql: "DELETE FROM pairedDevice")
            try db.execute(sql: """
                INSERT INTO device(id, name) VALUES('whoop-12345678', 'WHOOP 5');
                INSERT INTO pairedDevice(id,brand,model,sourceKind,capabilities,status,addedAt,lastSeenAt,peripheralId)
                VALUES('whoop-12345678','WHOOP','WHOOP 5','liveBLE','hr','active',1,2,'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC');
                INSERT INTO hrSample(deviceId,ts,bpm) VALUES('whoop-12345678',100,65);
                """)
        }
        let target = try await WhoopStore.inMemory()
        try await CloudCaptureScope.prepareStore(target.registryWriter, legacyPath: oldPath,
                                                 ownerId: ownerA, sourceId: sourceA)
        try await CloudCaptureScope.prepareStore(target.registryWriter, legacyPath: oldPath,
                                                 ownerId: ownerA, sourceId: sourceA)
        let targetCounts = try await target.registryWriter.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM hrSample"),
             try String.fetchOne(db, sql: "SELECT id FROM pairedDevice WHERE status = 'active'"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM cloudCaptureIdentity"))
        }
        XCTAssertEqual(targetCounts.0, 0)
        XCTAssertEqual(targetCounts.1, "whoop-12345678")
        XCTAssertEqual(targetCounts.2, 1)
        let oldSamples = try await legacy.registryWriter.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM hrSample") }
        XCTAssertEqual(oldSamples, 1)
    }

    func testOwnerAndSourceCannotRebindAnExistingBuffer() async throws {
        let store = try await WhoopStore.inMemory()
        try await CloudCaptureScope.prepareStore(store.registryWriter, legacyPath: nil, ownerId: ownerA, sourceId: sourceA)
        for (owner, source) in [(ownerB, sourceA), (ownerA, sourceB)] {
            do {
                try await CloudCaptureScope.prepareStore(store.registryWriter, legacyPath: nil, ownerId: owner, sourceId: source)
                XCTFail("A buffer cannot change owner or installation")
            } catch CloudCaptureScope.ScopeError.ownerMismatch { }
        }
    }

    func testUnownedSamplesAreRejectedWithoutModification() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('my-whoop',100,65)")
        }
        do {
            try await CloudCaptureScope.prepareStore(store.registryWriter, legacyPath: nil, ownerId: ownerA, sourceId: sourceA)
            XCTFail("Legacy data must not acquire an owner from a code response")
        } catch CloudCaptureScope.ScopeError.unownedHistory { }
        let count = try await store.registryWriter.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM hrSample") }
        XCTAssertEqual(count, 1)
    }
}
