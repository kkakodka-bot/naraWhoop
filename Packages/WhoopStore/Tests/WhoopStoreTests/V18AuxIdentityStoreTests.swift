import Foundation
import GRDB
import WhoopProtocol
import XCTest
@testable import WhoopStore

final class V18AuxIdentityStoreTests: XCTestCase {
    private let scope = DurableIngestScope(environment: "https://fixture.invalid",
        accountID: "11111111-1111-4111-8111-111111111111", deviceID: "strap")

    private func store() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        // Allows this isolated checkpoint to run before root adds the approved registrations.
        try await store.registryWriter.write { db in
            if !(try db.columns(in: "v18AuxSample")).contains(where: { $0.name == "resourceKey" }) {
                try WhoopStore.installV18AuxIdentitySchema(db)
            }
            if !(try db.columns(in: "stepSample")).contains(where: { $0.name == "provenanceJSON" }) {
                try WhoopStore.installScalarProvenanceSchema(db)
            }
        }
        try await store.bindAccountOwner(projectURL: scope.environment!, userID: scope.accountID!)
        return store
    }

    func testSameSecondSiblingsUnknownAndZeroSurviveReplayAndKeepDistinctKeys() async throws {
        let s = try await store()
        let samples = [nil, 0, 1, Int(UInt32.max)].map { V18AuxSample(ts: 100, recordIndex: $0, statusWord: 7) }
        _ = try await s.insert(Streams(v18Aux: samples.reversed()), deviceId: "strap")
        let initialDebt = try await s.owedJobs()
        _ = try await s.insert(Streams(v18Aux: samples), deviceId: "strap")
        let rows = try await s.v18AuxSamples(deviceId: "strap", from: 100, to: 100)
        XCTAssertEqual(rows, samples)
        let debt = try await s.owedJobs()
        XCTAssertEqual(debt.first?.token, initialDebt.first?.token)
        let keys = try await s.registryWriter.read { db in
            try String.fetchAll(db, sql: "SELECT resourceKey FROM v18AuxSample ORDER BY recordIndex")
        }
        XCTAssertEqual(keys, ["100:-1", "100:0", "100:1", "100:4294967295"])
    }

    func testConflictingIdentityRollsBackMixedChunkAndKeepsOriginalBytes() async throws {
        let s = try await store()
        let original = V18AuxSample(ts: 100, recordIndex: 1, statusWord: 7)
        _ = try await s.insert(Streams(v18Aux: [original]), deviceId: "strap")
        do {
            _ = try await s.insert(Streams(hr: [HRSample(ts: 101, bpm: 70)],
                v18Aux: [V18AuxSample(ts: 100, recordIndex: 1, statusWord: 8)]), deviceId: "strap")
            XCTFail("a changed payload is not an idempotent duplicate")
        } catch { XCTAssertEqual(error as? DurableIngestError, .identityConflict) }
        let aux = try await s.v18AuxSamples(deviceId: "strap", from: 0, to: 200)
        let hr = try await s.hrSamples(deviceId: "strap", from: 0, to: 200, limit: 10)
        XCTAssertEqual(aux, [original]); XCTAssertTrue(hr.isEmpty)
    }

    func testReplayKeepsMigratedRowidResourceKeyAndLedgerWithoutFreshDebt() async throws {
        let s = try await store()
        let original = V18AuxSample(ts: 100, recordIndex: 42, statusWord: 7)
        let bytes = V18AuxCodec.pack(original)
        let capture = scope
        try await s.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO v18AuxSample(rowid,deviceId,ts,recordIndex,fields,resourceKey)
                VALUES (-9,'strap',100,42,?,'100')
                """, arguments: [bytes])
            try WhoopStore.registerRawResource(db, scope: capture, lane: "v18AuxSample", key: "100", bytes: bytes)
        }
        _ = try await s.insert(Streams(v18Aux: [original]), deviceId: "strap")
        try await s.registryWriter.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT rowid,fields,resourceKey FROM v18AuxSample"))
            XCTAssertEqual(row["rowid"] as Int64, -9)
            XCTAssertEqual(row["resourceKey"] as String, "100")
            XCTAssertEqual(row["fields"] as Data, bytes)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT resourceKey FROM ingestRawResource"), ["100"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rawDurabilityReceipt"), 0)
        }
        let debt = try await s.owedJobs()
        XCTAssertTrue(debt.isEmpty)
    }

    func testInvalidRecordIndexRejectsWholeChunkWithoutTruncation() async throws {
        let s = try await store()
        for invalid in [-1, Int(UInt32.max) + 1] {
            do {
                _ = try await s.insert(Streams(hr: [HRSample(ts: 101, bpm: 70)],
                    v18Aux: [V18AuxSample(ts: 100, recordIndex: invalid)]), deviceId: "strap")
                XCTFail("an invalid known index must not become unknown or wrap to u32")
            } catch { XCTAssertEqual(error as? DurableIngestError, .identityConflict) }
        }
        let aux = try await s.v18AuxSamples(deviceId: "strap", from: 0, to: 200)
        let hr = try await s.hrSamples(deviceId: "strap", from: 0, to: 200, limit: 10)
        let debt = try await s.owedJobs()
        XCTAssertTrue(aux.isEmpty); XCTAssertTrue(hr.isEmpty); XCTAssertTrue(debt.isEmpty)
    }

    func testReceiptPruneCountsIndividualSiblingsWithoutDeletingUnsent() async throws {
        let s = try await store()
        _ = try await s.insert(Streams(v18Aux: (0..<4).map { V18AuxSample(ts: 100, recordIndex: $0) }),
            deviceId: "strap", v18AuxRetentionRows: 2, v18AuxPruneEveryRows: 1)
        let held = try await s.v18AuxSamples(deviceId: "strap", from: 0, to: 200)
        XCTAssertEqual(held.count, 4)
        for index in [0, 2] {
            let resource = try await s.rawResourceIdentity(scope: scope, lane: "v18AuxSample", resourceKey: "100:\(index)")
            let identity = try XCTUnwrap(resource)
            try await s.recordRawDurabilityReceipt(RawDurabilityReceipt(scope: scope, lane: "v18AuxSample",
                resourceKey: identity.resourceKey, contentSHA256: identity.contentSHA256, objectKey: "fixture/object",
                receiptID: "fixture-receipt", verifiedAt: 1, retainUntil: 2))
        }
        _ = try await s.insert(Streams(v18Aux: [V18AuxSample(ts: 100, recordIndex: 4)]),
            deviceId: "strap", v18AuxRetentionRows: 2, v18AuxPruneEveryRows: 1)
        let kept = try await s.v18AuxSamples(deviceId: "strap", from: 0, to: 200)
        XCTAssertEqual(kept.compactMap(\.recordIndex), [1, 3, 4], "unsent older sibling survives; newest two stay")
    }

    func testWrongCapturedOwnerRejectedEvenForDuplicate() async throws {
        let s = try await store()
        let streams = Streams(v18Aux: [V18AuxSample(ts: 100, recordIndex: 1)])
        _ = try await s.insert(streams, deviceId: "strap")
        do {
            _ = try await s.insertAndMarkJobsOwed(streams, deviceId: "strap", postOffloadJobKinds: [], note: nil,
                captureScope: DurableIngestScope(environment: scope.environment, accountID: "other", deviceID: "strap"))
            XCTFail("even duplicates must stay in their captured account")
        } catch { XCTAssertEqual(error as? DurableIngestError, .identityConflict) }
    }

    func testScalarProvenanceRoundTripsAndReplayNeverEnrichesLegacyRows() async throws {
        let s = try await store()
        let direct = try ScalarProvenance(origin: .whoopV18, recordIndex: 1, frameSHA256: String(repeating: "a", count: 64))
        let derived = try ScalarProvenance(origin: .whoopV26PpgDerived, algorithm: .ppgACF, sampleRateHz: 24,
            windowSettingSeconds: 8, inputStartTs: 1, inputEndTs: 4, inputSHA256: String(repeating: "b", count: 64))
        _ = try await s.insert(Streams(steps: [StepSample(ts: 1, counter: 0)],
            sleepState: [SleepStateSample(ts: 1, state: 0)], ppgHr: [PpgHrSample(ts: 1, bpm: 60, conf: 0.5)]), deviceId: "strap")
        let current = Streams(steps: [StepSample(ts: 2, counter: 65535, activityClass: 2, provenance: direct)],
            sleepState: [SleepStateSample(ts: 2, state: 3, rawByte: 0x30, provenance: direct)],
            ppgHr: [PpgHrSample(ts: 2, bpm: 70, conf: 0.9, provenance: derived)])
        _ = try await s.insert(current, deviceId: "strap")
        _ = try await s.insert(Streams(steps: [StepSample(ts: 1, counter: 0, provenance: direct)]), deviceId: "strap")
        let steps = try await s.stepSamples(deviceId: "strap", from: 0, to: 3, limit: 10)
        let states = try await s.sleepStateSamples(deviceId: "strap", from: 0, to: 3)
        let ppg = try await s.ppgHrSamples(deviceId: "strap", from: 0, to: 3)
        XCTAssertNil(steps[0].provenance); XCTAssertNil(states[0].provenance); XCTAssertNil(ppg[0].provenance)
        XCTAssertEqual(steps[1], current.steps[0]); XCTAssertEqual(states[1], current.sleepState[0])
        XCTAssertEqual(ppg[1], current.ppgHr[0])
        let page = try await s.stepSamplesPage(deviceId: "strap", afterExclusive: 1, endExclusive: 3, limit: 10)
        XCTAssertEqual(page, current.steps)
    }

    func testScalarDebtFailureRollsBackRowAndProvenanceTogether() async throws {
        let s = try await store()
        try await s.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_debt BEFORE INSERT ON syncJob BEGIN SELECT RAISE(ABORT, 'fixture'); END;
                """)
        }
        let direct = try ScalarProvenance(origin: .whoopV18, recordIndex: 1)
        do {
            _ = try await s.insert(Streams(steps: [StepSample(ts: 1, counter: 1, provenance: direct)]), deviceId: "strap")
            XCTFail("debt failure must abort the entire write")
        } catch { }
        let rows = try await s.stepSamples(deviceId: "strap", from: 0, to: 2, limit: 10)
        XCTAssertTrue(rows.isEmpty)
    }
}
