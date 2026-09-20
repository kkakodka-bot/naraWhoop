import XCTest
import WhoopProtocol
import GRDB
@testable import WhoopStore

final class RRPacketProvenanceStoreTests: XCTestCase {
    func testDeviceRekeyPreservesReceiptBytesAndDeletionIsOwnerScoped() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let p = try XCTUnwrap(RRPacketProvenance.checked(RRPacketProvenance.bytes("aa011800010022e12f12000000000000f153650000003c0200040002700d85e7")!))
        for owner in ["my-whoop", "other-owner"] {
            _ = try await store.insert(Streams(rrPackets: [p]), deviceId: owner)
        }
        XCTAssertTrue(try registry.adoptSerialIdentity(from: "my-whoop", to: "whoop-test-serial"))
        let old = try await store.rrPacketProvenance(deviceId: "my-whoop", from: p.ts, to: p.ts + 1)
        let moved = try await store.rrPacketProvenance(deviceId: "whoop-test-serial", from: p.ts, to: p.ts + 1)
        XCTAssertTrue(old.isEmpty); XCTAssertEqual(moved, [p])
        try registry.deleteAllData(deviceId: "whoop-test-serial")
        let deleted = try await store.rrPacketProvenance(deviceId: "whoop-test-serial", from: p.ts, to: p.ts + 1)
        let other = try await store.rrPacketProvenance(deviceId: "other-owner", from: p.ts, to: p.ts + 1)
        XCTAssertTrue(deleted.isEmpty); XCTAssertEqual(other, [p])
    }

    func testReceiptOnlySourceWitnessDoesNotOverrideKnownDeviceFamily() async throws {
        let store = try await WhoopStore.inMemory()
        let id = "my-whoop"
        func registry(model: String, brand: String = "WHOOP") throws {
            try store.registryWriter.write { db in
                try db.execute(sql: "UPDATE pairedDevice SET model=?,brand=? WHERE id=?", arguments: [model,brand,id])
            }
        }
        try registry(model: "WHOOP")
        let before = try await store.isWhoop5RRSource(deviceId: id)
        XCTAssertFalse(before)
        let oldWitness = try await store.dayStreamFingerprint(deviceId: id, from: 0, to: 1)
        let p = try XCTUnwrap(RRPacketProvenance.checked(RRPacketProvenance.bytes("aa011800010022e12f12000000000000f153650000003c0200040002700d85e7")!))
        _ = try await store.insert(Streams(rrPackets: [p]), deviceId: id)
        let receiptWitness = try await store.isWhoop5RRSource(deviceId: id)
        XCTAssertTrue(receiptWitness)
        let newWitness = try await store.dayStreamFingerprint(deviceId: id, from: 0, to: 1)
        XCTAssertNotEqual(oldWitness, newWitness, "owner classification changes even outside the packet's time window")
        let unrelated = try await store.isWhoop5RRSource(deviceId: "other-owner")
        XCTAssertFalse(unrelated)
        try registry(model: "4.0")
        let four = try await store.isWhoop5RRSource(deviceId: id)
        XCTAssertFalse(four)
        try registry(model: "5.0 MG", brand: "Oura")
        let nonWhoop = try await store.isWhoop5RRSource(deviceId: id)
        XCTAssertFalse(nonWhoop)
    }

    func testPacketOnlyBackfillIsAtomicAndReplayDoesNotInventLegacyIdentity() async throws {
        let store = try await WhoopStore.inMemory()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rr_packet_provenance_oracle", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let zeroCase = try XCTUnwrap(cases.first { ($0["rawTicks"] as? [Int])?.contains(0) == true })
        let packet = try XCTUnwrap(RRPacketProvenance.checked(RRPacketProvenance.bytes(try XCTUnwrap(zeroCase["hex"] as? String))!))
        XCTAssertEqual(packet.packetId, zeroCase["packetId"] as? String)
        let batch = Streams(rrPackets: [packet])
        let beforeGlobal = try await store.analysisFingerprint()
        let beforeDay = try await store.dayStreamFingerprint(deviceId: "d", from: packet.ts, to: packet.ts)
        let otherOwner = try await store.dayStreamFingerprint(deviceId: "other", from: packet.ts, to: packet.ts)
        let first = try await store.insertAndMarkJobsOwed(batch, deviceId: "d", postOffloadJobKinds: ["rr-provenance"])
        XCTAssertEqual(first.counts.rr, 0); XCTAssertTrue(first.markedJobs)
        let afterGlobal = try await store.analysisFingerprint()
        let afterDay = try await store.dayStreamFingerprint(deviceId: "d", from: packet.ts, to: packet.ts)
        XCTAssertNotEqual(beforeGlobal, afterGlobal); XCTAssertNotEqual(beforeDay, afterDay)
        let unchangedOther = try await store.dayStreamFingerprint(deviceId: "other", from: packet.ts, to: packet.ts)
        XCTAssertEqual(otherOwner, unchangedOther)
        let second = try await store.insertAndMarkJobsOwed(batch, deviceId: "d", postOffloadJobKinds: ["rr-provenance"])
        XCTAssertEqual(second.counts.rr, 0); XCTAssertFalse(second.markedJobs)
        let replayGlobal = try await store.analysisFingerprint()
        let replayDay = try await store.dayStreamFingerprint(deviceId: "d", from: packet.ts, to: packet.ts)
        XCTAssertEqual(afterGlobal, replayGlobal); XCTAssertEqual(afterDay, replayDay)
        let loaded = try await store.rrPacketProvenance(deviceId: "d", from: packet.ts, to: packet.ts + 1)
        XCTAssertEqual(loaded, [packet]); XCTAssertEqual(loaded[0].words.map(\.index), [0,1,2])
        XCTAssertEqual(loaded[0].words.map(\.rawTicks), [1024,0,512])
    }
    func testMigrationDoesNotBackfillProofFromLegacyValues() throws {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq, upTo: "v49-owner-scoped-physiology-cache")
        try dbq.write { db in try db.execute(sql: "INSERT INTO rrInterval(deviceId,ts,rrMs) VALUES('d',1700000000,1000)") }
        try WhoopStore.makeMigrator().migrate(dbq)
        try dbq.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM rrInterval"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM rrPacketProvenance"), 0)
        }
    }
}
