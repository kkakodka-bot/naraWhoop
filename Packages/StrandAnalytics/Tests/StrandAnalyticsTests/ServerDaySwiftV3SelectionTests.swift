import Foundation
import GRDB
import WhoopProtocol
import XCTest
@testable import StrandAnalytics

final class ServerDaySwiftV3SelectionTests: XCTestCase {
    private typealias V = ServerDaySwiftV3Contract
    private typealias S = ServerDaySwiftV3Selection
    private typealias F = S10Fixtures

    private func load(_ input: V.Input) async throws -> S.Loaded {
        let seed = try await S.seed(input)
        return try await S.load(seed)
    }

    func testContradictoryKnownRegistryLabelsFailBeforeAnyDataIsSeeded() async throws {
        for (family, model) in [("whoop5", "WHOOP 4.0"), ("whoop4", "WHOOP 5.0"), ("whoop5", "")] {
            let i = try F.input(family: family, model: model)
            do { _ = try await S.seed(i); XCTFail("Do not relabel original registry identity") }
            catch { XCTAssertEqual(error as? ServerDaySwiftContract.Failure, .invalid("s10:known_family_registry_conflict")) }
        }
    }

    func testKnownFamiliesUseActualStoreAndStored2IsNotWire110() async throws {
        for (family, model, expected) in [("whoop5", "WHOOP 5.0", ["c5"]),
            ("whoop4", "WHOOP 4.0", ["nil", "c110", "c7", "c6", "c5"])] {
            var i = try F.input(family: family, model: model)
            let lo = try V.validate(i).dayLo
            for (index, channel) in [nil, 2, 110, 7, 6, 5].enumerated() {
                F.append(&i, .rr, lo + index, F.rr(channel: channel), id: channel.map { "c\($0)" } ?? "nil")
            }
            F.append(&i, .rr, lo + 7, F.rr(channel: 5, suspect: 1), id: "suspect")
            let loaded = try await load(i), p = loaded.evidence.rrPolicy
            XCTAssertEqual(p.serverWindowIDs, expected)
            XCTAssertEqual(p.shippedStoreIDs, expected)
            XCTAssertEqual(p.adapter, "actual-store-known-family")
            XCTAssertEqual(loaded.evidence.retainedByOwner[F.owner.uuidString.lowercased()]?["rr"], 7)
            XCTAssertEqual(loaded.rr.count, expected.count)
            if family == "whoop4" {
                XCTAssertEqual(loaded.evidence.streams["rr"]?[1].fields["srcChannel"], .number(110))
                XCTAssertNil(loaded.rr[1].srcChannel) // Native enum has no wire-tag alias.
            }
        }
    }

    func testChannel7FallbackAnd6OnlyStrictEmptyRemainDistinctFromLegacy() async throws {
        for (family, model, channel, expected) in [("whoop5", "WHOOP 5.0", 7, 1),
            ("whoop5", "WHOOP 5.0", 6, 0), ("whoop4", "WHOOP 4.0", 6, 1)] {
            var i = try F.input(family: family, model: model)
            F.append(&i, .rr, i.asOfExclusive - 10, F.rr(channel: channel), id: "row")
            let loaded = try await load(i)
            XCTAssertEqual(loaded.rr.count, expected)
            XCTAssertEqual(loaded.evidence.rrPolicy.canonicalChannel, channel == 7 ? 7 : nil)
        }
        var unknown = try F.input(family: nil, model: "")
        F.append(&unknown, .rr, unknown.asOfExclusive - 10, F.rr(channel: 6))
        let loaded = try await load(unknown)
        XCTAssertTrue(loaded.evidence.rrPolicy.canonicalOnly)
        XCTAssertTrue(loaded.rr.isEmpty)
    }

    func testUnknownFamilyFutureAndSuspectEvidencePreservesShippedStoreDisagreement() async throws {
        for suspectOnly in [false, true] {
            var i = try F.input(family: nil, model: "")
            let ts = i.asOfExclusive - 10
            F.append(&i, .rr, ts, F.rr(channel: nil), id: "legacy-null")
            F.append(&i, .rr, suspectOnly ? ts + 1 : i.asOfExclusive, F.rr(channel: 5, suspect: suspectOnly ? 1 : 0), id: "modern-evidence")
            let seed = try await S.seed(i), loaded = try await S.load(seed)
            let p = loaded.evidence.rrPolicy
            XCTAssertEqual(p.adapter, "server-window-unknown-family-v1")
            XCTAssertFalse(p.windowHasModern)
            XCTAssertFalse(p.canonicalOnly)
            XCTAssertTrue(p.shippedStoreCanonicalOnly)
            XCTAssertEqual(p.shippedStoreIDs, [])
            XCTAssertEqual(p.serverWindowIDs, ["legacy-null"])
            XCTAssertEqual(loaded.evidence.retainedByOwner[F.owner.uuidString.lowercased()]?["rr"], 2)
            let original = try await seed.store.registryWriter.read { db in
                try Row.fetchOne(db, sql: "SELECT brand,model FROM pairedDevice WHERE id=?", arguments: [F.device.uuidString.lowercased()])!
            }
            XCTAssertEqual(original["model"] as String, "")
            XCTAssertEqual(original["brand"] as String, "WHOOP")
        }
    }

    func testExplicitUnknownStringDoesNotBecomeNullFamilyAndKeepsBothRows() async throws {
        var i = try F.input(family: "unknown", model: "unknown")
        F.append(&i, .rr, i.asOfExclusive - 2, F.rr(channel: nil), id: "legacy")
        F.append(&i, .rr, i.asOfExclusive - 1, F.rr(channel: 5), id: "modern")
        let loaded = try await load(i)
        XCTAssertTrue(loaded.evidence.rrPolicy.windowHasModern)
        XCTAssertFalse(loaded.evidence.rrPolicy.canonicalOnly)
        XCTAssertEqual(loaded.evidence.rrPolicy.serverWindowIDs, ["legacy", "modern"])
        XCTAssertEqual(loaded.evidence.rrPolicy.shippedStoreIDs, ["modern"])
    }

    func testRealRowidsOrdinalTieOrderingAndOwnerDeviceIsolation() async throws {
        var i = try F.input()
        let ts = i.asOfExclusive - 10
        F.append(&i, .rr, ts, F.rr(900, ord: 1, seq: 2), id: "ord1-seq2")
        F.append(&i, .rr, ts, F.rr(900, ord: nil, seq: 3), id: "ord-null")
        F.append(&i, .rr, ts, F.rr(850, ord: 1, seq: 4), id: "ord1-ms850")
        F.append(&i, .rr, ts, F.rr(900, ord: 1, seq: 1), id: "ord1-seq1")
        F.append(&i, .rr, ts, F.rr(999), id: "foreign-owner", owner: F.foreign)
        F.append(&i, .rr, ts, F.rr(999), id: "foreign-device", device: F.otherDevice)
        let seed = try await S.seed(i), loaded = try await S.load(seed)
        let selected = try XCTUnwrap(loaded.evidence.streams["rr"])
        XCTAssertEqual(selected.map(\.id), ["ord-null", "ord1-ms850", "ord1-seq1", "ord1-seq2"])
        XCTAssertEqual(selected.map(\.rowid), [2, 3, 4, 1])
        XCTAssertEqual(loaded.evidence.retainedByOwner[F.owner.uuidString.lowercased()]?["rr"], 5)
        XCTAssertEqual(loaded.evidence.retainedByOwner[F.foreign.uuidString.lowercased()]?["rr"], 1)
        for (owner, store) in seed.stores {
            let boundOwner = try await store.registryWriter.read { try String.fetchOne($0, sql: "SELECT userID FROM localAccountOwner") }
            XCTAssertEqual(boundOwner, owner.uuidString.lowercased())
        }
    }

    func testHistoricalStepPredecessorAndInclusiveNightEdgesButSeparateDayMembership() async throws {
        var i = try F.input()
        let b = try V.validate(i)
        for (id, ts, counter) in [("older", b.nightLo - 2, 10), ("predecessor", b.nightLo - 1, 11),
            ("nightLo", b.nightLo, 12), ("beforeDay", b.dayLo - 1, 13), ("dayLo", b.dayLo, 14),
            ("dayHi", b.dayHi, 15), ("future", b.dayHi + 1, 16)] {
            F.append(&i, .steps, ts, ["counter": .number(Double(counter))], id: id)
        }
        let loaded = try await load(i)
        XCTAssertEqual(loaded.evidence.streams["steps"]?.map(\.id), ["predecessor", "nightLo", "beforeDay", "dayLo", "dayHi"])
        XCTAssertEqual(loaded.evidence.stepPredecessor, "predecessor")
        XCTAssertEqual(loaded.evidence.daySteps, ["dayLo", "dayHi"])
        XCTAssertEqual(loaded.evidence.retainedByOwner[F.owner.uuidString.lowercased()]?["steps"], 7)
    }

    func testInvalidNearestPredecessorDoesNotRescueOlderCounter() async throws {
        var i = try F.input()
        let b = try V.validate(i)
        F.append(&i, .steps, b.nightLo - 2, ["counter": .number(10)], id: "older-valid")
        F.append(&i, .steps, b.nightLo - 1, ["counter": .number(-1)], id: "nearest-invalid")
        F.append(&i, .steps, b.dayLo, ["counter": .number(12)], id: "day")
        let loaded = try await load(i)
        XCTAssertNil(loaded.evidence.stepPredecessor)
        XCTAssertEqual(loaded.evidence.streams["steps"]?.map(\.id), ["day"])
        XCTAssertTrue(loaded.evidence.gaps.contains("stepSample_measurement_invalid"))
        XCTAssertEqual(loaded.evidence.retainedByOwner[F.owner.uuidString.lowercased()]?["steps"], 3)
    }

    func testMeasuredHRIsNotReplacedByDerivedPPGAndActualStoreReadMatches() async throws {
        var i = try F.input()
        let ts = i.asOfExclusive - 10
        F.append(&i, .hr, ts, ["bpm": .number(60)], id: "measured")
        F.append(&i, .ppgHr, ts, ["bpm": .number(90), "conf": .number(0.8)], id: "derived-collision")
        F.append(&i, .ppgHr, ts + 1, ["bpm": .number(70), "conf": .number(0.6)], id: "derived-only")
        let seed = try await S.seed(i), loaded = try await S.load(seed)
        XCTAssertEqual(loaded.hr.map(\.bpm), [60])
        XCTAssertEqual(loaded.evidence.dayHr, ["measured"])
        XCTAssertEqual(loaded.ppgHr.map(\.bpm), [90, 70])
        let actual = try await seed.store.ppgHrSamples(deviceId: F.device.uuidString.lowercased(), from: ts, to: ts + 1)
        XCTAssertEqual(loaded.ppgHr, actual)
        XCTAssertTrue(loaded.evidence.gaps.contains("ppgHrSample_provenance_unknown"))
    }

    func testNativeStoreRejectsMissingConfidenceWithoutInventingLegacyMetadata() async throws {
        for conf in [nil, ServerDaySwiftContract.JSON.null] {
            var i = try F.input(), fields: [String: ServerDaySwiftContract.JSON] = ["bpm": .number(70)]
            fields["conf"] = conf
            F.append(&i, .ppgHr, i.asOfExclusive - 1, fields)
            _ = try V.validate(i) // Server-compatible raw envelope retains absence/null.
            do { _ = try await S.seed(i); XCTFail("Native NOT NULL must not be bypassed with fabricated confidence") }
            catch { XCTAssertTrue(error is DatabaseError) }
        }
    }

    func testActualSwiftDerivedPPGAndProvenanceSurviveStoreWithoutCreatingMeasuredHR() async throws {
        var i = try F.input()
        let start = try V.validate(i).dayLo
        let waveforms = (0..<32).map { second in
            PpgWaveformSample(ts: start + second, samples: (0..<24).map { sample in
                Int((1_000 * sin(2 * Double.pi * 1.2 * Double(second * 24 + sample) / 24)).rounded())
            }, recordIndex: second)
        }
        let derived = PpgHr.derivePpgHr(waveforms: waveforms)
        XCTAssertFalse(derived.isEmpty)
        for sample in derived {
            let provenance = try XCTUnwrap(sample.provenance)
            XCTAssertEqual(provenance.inputSelection, .lastRecordPerSecond)
            F.append(&i, .ppgHr, sample.ts, ["bpm": .number(Double(sample.bpm)), "conf": .number(sample.conf),
                "provenance": try V.json(provenance)])
        }
        let loaded = try await load(i)
        XCTAssertEqual(loaded.ppgHr, derived)
        XCTAssertTrue(loaded.hr.isEmpty)
        XCTAssertTrue(loaded.evidence.dayHr.isEmpty)
        XCTAssertFalse(loaded.evidence.gaps.contains("ppgHrSample_provenance_unknown"))
        XCTAssertEqual(loaded.evidence.streams["ppgHr"]?.map(\.id), i.raw.map(\.id))
    }

    func testOriginalProvenanceRoundTripsAndFutureInputWindowIsRejectedWithoutDeletion() async throws {
        var i = try F.input()
        let b = try V.validate(i), digest = String(repeating: "a", count: 64)
        let direct = try ScalarProvenance(origin: .whoopV18, recordIndex: 7, frameSHA256: digest)
        let future = try ScalarProvenance(origin: .whoopV26PpgDerived, algorithm: .ppgACF, sampleRateHz: 24,
            windowSettingSeconds: 30, inputStartTs: b.dayHi - 30, inputEndTs: b.dayHi + 2, inputSHA256: digest,
            inputSelection: .lastRecordPerSecond)
        F.append(&i, .steps, b.dayLo, ["counter": .number(12), "provenance": try V.json(direct)], id: "direct")
        F.append(&i, .ppgHr, b.dayHi, ["bpm": .number(60), "conf": .number(0.7), "provenance": try V.json(future)], id: "future-window")
        let loaded = try await load(i)
        XCTAssertEqual(loaded.steps.first?.provenance, direct)
        XCTAssertEqual(loaded.evidence.streams["steps"]?.first?.fields["provenance"], try V.json(direct))
        XCTAssertTrue(loaded.ppgHr.isEmpty)
        XCTAssertTrue(loaded.evidence.gaps.contains("ppgHrSample_provenance_invalid"))
        XCTAssertEqual(loaded.evidence.retainedByOwner[F.owner.uuidString.lowercased()]?["ppgHr"], 1)
    }

    func testInvalidScalarProvenanceAndDecodedRawMismatchAreRetainedButNotSelected() async throws {
        var i = try F.input()
        let ts = i.asOfExclusive - 10
        F.append(&i, .bandState, ts, ["state": .number(1), "rawByte": .number(1)], id: "v1-inconsistent")
        F.append(&i, .bandState, ts + 1, ["state": .number(1), "rawByte": .number(16)], id: "consistent")
        F.append(&i, .steps, ts, ["counter": .number(10), "provenance": .object(["frameIndex": .null])], id: "bad-provenance")
        F.append(&i, .ppgHr, ts, ["bpm": .number(60), "conf": .number(1.1)], id: "bad-confidence")
        let loaded = try await load(i)
        XCTAssertEqual(loaded.evidence.streams["bandState"]?.map(\.id), ["consistent"])
        XCTAssertTrue(loaded.steps.isEmpty)
        XCTAssertTrue(loaded.ppgHr.isEmpty)
        XCTAssertTrue(loaded.evidence.gaps.contains("sleepStateSample_measurement_invalid"))
        XCTAssertTrue(loaded.evidence.gaps.contains("stepSample_provenance_invalid"))
        XCTAssertTrue(loaded.evidence.gaps.contains("ppgHrSample_measurement_invalid"))
        XCTAssertEqual(loaded.evidence.retainedByOwner[F.owner.uuidString.lowercased()]?["bandState"], 2)
        XCTAssertEqual(loaded.evidence.retainedByOwner[F.owner.uuidString.lowercased()]?["steps"], 1)
    }

    func testScalarUnitsAndEventsUseActualStoreValuesWithoutThermalCompositionClaim() async throws {
        var i = try F.input()
        let ts = i.asOfExclusive - 10
        F.append(&i, .resp, ts, ["raw": .number(1234)])
        F.append(&i, .gravity, ts, ["x": .number(0.1), "y": .number(-0.2), "z": .number(0.9), "dynAccel": .number(0.03)])
        F.append(&i, .skinTemp, ts, ["raw": .number(3301), "aux1Raw": .number(120), "aux2Raw": .number(130)])
        F.append(&i, .spo2, ts, ["red": .number(1001), "ir": .number(1201)])
        F.append(&i, .events, ts, ["kind": .string("off_body"), "payloadJSON": .string("{}")])
        let loaded = try await load(i)
        XCTAssertEqual(loaded.resp.first?.raw, 1234)
        XCTAssertEqual(loaded.gravity.first?.x, 0.1)
        XCTAssertEqual(loaded.skinTemp.first?.raw, 3301)
        XCTAssertEqual(loaded.spo2.first?.red, 1001)
        XCTAssertEqual(loaded.events.first?.kind, "off_body")
        XCTAssertEqual(loaded.evidence.scoringResp, i.raw.filter { $0.stream == .resp }.map(\.id))
    }

    func testConflictingPhysicalPrimaryKeyIsNotSilentlyOverwritten() async throws {
        var i = try F.input()
        F.append(&i, .rr, i.asOfExclusive - 1, F.rr(), id: "one")
        F.append(&i, .rr, i.asOfExclusive - 1, F.rr(), id: "different-logical-id-same-physical-key")
        do { _ = try await S.seed(i); XCTFail("Conflicting SQLite key must fail") }
        catch { XCTAssertTrue(error is DatabaseError) }
    }
}
