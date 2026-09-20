import Foundation
import XCTest
@testable import StrandAnalytics

// Synthetic inputs only. Row IDs are fixture labels; rowid is assigned by real SQLite.
enum S10Fixtures {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    static let owner = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let device = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let foreign = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let otherDevice = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

    static func input(_ id: String = "s10", day: String = "2026-06-15", zone: String = "UTC",
                      family: String? = "whoop5", model: String = "WHOOP 5.0") throws -> V.Input {
        let bounds = try C.dayBounds(day, zone)
        return V.Input(id: id, identity: C.Identity(userId: owner, sourceDeviceId: device, algorithmVersion: "s10-native-core-v1"),
            source: V.Source(externalDeviceId: "s10-synthetic-device", registryFamily: family, storeModel: model, storeBrand: "WHOOP"),
            day: day, timezone: zone, asOfExclusive: bounds.upperBound,
            journal: [journal(.profile, 1, day: day, payload: ["timezone": .string(zone), "age": .number(30),
                "weightKg": .number(70), "heightCm": .number(170), "sex": .string("nonbinary"), "waistCm": .null]),
                journal(.config, 2, day: day, payload: ["dayCycleMode": .string("midnight"), "useSleepStagerV2": .bool(false),
                    "useMotionAwareWake": .bool(false), "effortMethod": .string("EDWARDS")])])
    }

    static func journal(_ kind: C.Kind, _ revision: Int64, day: String = "2026-06-15", deleted: Bool = false,
                        payload: [String: C.JSON] = [:], owner: UUID = owner, device: UUID = device) -> C.JournalRow {
        var payload = payload
        if !deleted { payload["schemaVersion"] = .number(1) }
        return C.JournalRow(userId: owner, sourceDeviceId: device, kind: kind, entity: "primary", revision: revision,
            effectiveDay: day, deleted: deleted, payload: payload)
    }

    static func append(_ input: inout V.Input, _ stream: C.Stream, _ ts: Int, _ fields: [String: C.JSON],
                       id: String? = nil, owner: UUID = owner, device: UUID = device) {
        input.raw.append(C.RawRow(id: id ?? "\(stream.rawValue)-\(input.raw.count)", userId: owner, sourceDeviceId: device,
            stream: stream, ts: ts, fields: fields))
    }

    static func rr(_ ms: Int = 1_000, channel: Int? = 5, ord: Int? = 0, seq: Int = 0, suspect: Int? = 0) -> [String: C.JSON] {
        ["rrMs": .number(Double(ms)), "seq": .number(Double(seq)), "srcChannel": channel.map { .number(Double($0)) } ?? .null,
         "ord": ord.map { .number(Double($0)) } ?? .null, "tsSuspect": suspect.map { .number(Double($0)) } ?? .null]
    }

    static func dense(_ id: String, day: String, zone: String = "UTC", v2: Bool = false) throws -> V.Input {
        var i = try input(id, day: day, zone: zone)
        i.journal[1] = journal(.config, 2, day: day, payload: ["dayCycleMode": .string("midnight"),
            "useSleepStagerV2": .bool(v2), "useMotionAwareWake": .bool(false), "effortMethod": .string("EDWARDS")])
        let start = try V.validate(i).dayLo
        // Three hours of original synthetic measurements, including the exact final epoch edge.
        // Raw bytes and decoded state agree: 0x10 -> state 1, not the rejected v1 rawByte 1.
        for offset in 0...10_800 {
            let ts = start + offset
            append(&i, .hr, ts, ["bpm": .number(Double(52 + offset / 60 % 3))])
            append(&i, .rr, ts, rr(1_000 + [0, 40, 0, -40][offset % 4]))
            append(&i, .gravity, ts, ["x": .number(0), "y": .number(0), "z": .number(1)])
            if offset % 30 == 0 {
                append(&i, .resp, ts, ["raw": .number(Double(1_000 + [0, 100, 0, -100][offset / 30 % 4]))])
                append(&i, .skinTemp, ts, ["raw": .number(3_300)])
                append(&i, .spo2, ts, ["red": .number(1_000), "ir": .number(1_200)])
                append(&i, .bandState, ts, ["state": .number(1), "rawByte": .number(16)])
                append(&i, .steps, ts, ["counter": .number(Double(offset / 30))])
            }
        }
        return i
    }

    static func hrOnly() throws -> V.Input {
        var i = try input("hr-only")
        let start = try V.validate(i).dayLo
        for offset in stride(from: -16 * 3_600, to: 8 * 3_600, by: 10) {
            let sleeping = offset >= 0
            let bpm = (sleeping ? 64 : 74) + Int(sin(Double(offset) / (sleeping ? 900 : 500)) * (sleeping ? 5 : 11))
            append(&i, .hr, start + offset, ["bpm": .number(Double(bpm))])
            append(&i, .rr, start + offset, rr(60_000 / bpm))
        }
        return i
    }
}

final class ServerDaySwiftV3ContractTests: XCTestCase {
    private typealias V = ServerDaySwiftV3Contract
    private typealias C = ServerDaySwiftContract

    func testInputRoundTripRetainsNullAbsentBooleanOwnerAndOriginalSource() throws {
        var i = try S10Fixtures.input(family: nil, model: "")
        S10Fixtures.append(&i, .ppgHr, i.asOfExclusive - 1, ["bpm": .number(68), "conf": .null])
        S10Fixtures.append(&i, .steps, i.asOfExclusive, ["counter": .number(2)], owner: S10Fixtures.foreign)
        let bytes = try C.bytes(i)
        XCTAssertEqual(try V.decode(bytes), i)
        let root = try V.object(V.json(i)), source = try V.object(root["source"]!)
        XCTAssertEqual(source["registryFamily"], .null)
        XCTAssertEqual(i.raw[0].fields["conf"], .null)
        XCTAssertNil(i.raw[0].fields["provenance"])
        XCTAssertEqual(try V.validate(i).nightHi + 1, i.asOfExclusive)
    }

    func testExactDSTClosedDayBoundsAndIntradayRefusal() throws {
        for (day, zone, duration) in [("2026-03-08", "America/Los_Angeles", 82_800),
            ("2026-11-01", "America/Los_Angeles", 90_000), ("2026-10-04", "Australia/Lord_Howe", 84_600),
            ("2026-04-05", "Australia/Lord_Howe", 88_200), ("2026-06-15", "Asia/Kathmandu", 86_400)] {
            var i = try S10Fixtures.input(day: day, zone: zone)
            let b = try V.validate(i)
            XCTAssertEqual(b.dayRange.count, duration)
            XCTAssertEqual(b.nightLo, b.dayLo - 108_000)
            XCTAssertEqual(b.nightHi, b.dayHi)
            i.asOfExclusive -= 1
            XCTAssertThrowsError(try V.validate(i)) { XCTAssertEqual($0 as? C.Failure, .invalid("s10:intraday_unsupported")) }
        }
        for (day, zone) in [("2026-02-30", "UTC"), ("2011-12-30", "Pacific/Apia"), ("2026-01-01", "invalid")] {
            XCTAssertThrowsError(try S10Fixtures.input(day: day, zone: zone))
        }
    }

    func testStrictUnknownKeysRequiredFieldsTypesSafeIntegersAndNulls() throws {
        let original = try S10Fixtures.input()
        var root = try V.object(V.json(original)); root["futureField"] = .bool(true)
        XCTAssertThrowsError(try V.decode(C.bytes(C.JSON.object(root))))
        root = try V.object(V.json(original)); root.removeValue(forKey: "source")
        XCTAssertThrowsError(try V.decode(C.bytes(C.JSON.object(root))))
        for fields: [String: C.JSON] in [["rrMs": .number(900)], ["rrMs": .bool(true), "seq": .number(0)],
            ["rrMs": .null, "seq": .number(0)], ["rrMs": .number(900.5), "seq": .number(0)],
            ["rrMs": .number(900), "seq": .number(C.safeInteger + 1)],
            ["rrMs": .number(900), "seq": .number(0), "unexpected": .null]] {
            var i = original; S10Fixtures.append(&i, .rr, i.asOfExclusive - 1, fields)
            XCTAssertThrowsError(try V.validate(i))
            XCTAssertThrowsError(try V.decode(C.bytes(i)))
        }
        var i = original
        S10Fixtures.append(&i, .gravity, i.asOfExclusive - 1, ["x": .number(.infinity), "y": .number(0), "z": .number(1)])
        XCTAssertThrowsError(try V.validate(i))
        i.schemaVersion = 1; XCTAssertThrowsError(try V.validate(i))
        i = original; i.recipe = "s10-actual-swift-core-probe-v1"; XCTAssertThrowsError(try V.validate(i))
    }

    func testJournalAsOfAndOwnershipPreserveTombstonesWithoutFutureLeak() throws {
        var i = try S10Fixtures.input()
        i.journal += [S10Fixtures.journal(.profile, 3, deleted: true),
            S10Fixtures.journal(.profile, 4, day: "2026-06-16", payload: ["timezone": .string("Asia/Tokyo"), "age": .number(90)]),
            S10Fixtures.journal(.profile, 500, payload: ["timezone": .string("UTC"), "age": .number(80)], owner: S10Fixtures.foreign)]
        _ = try V.validate(i)
        let resolved = try C.resolve(i.historyInput)
        XCTAssertEqual(resolved.head(.profile)?.revision, 3)
        XCTAssertEqual(resolved.payload(.profile), [:])
        i.journal.reverse()
        XCTAssertEqual(try C.resolve(i.historyInput), resolved)
    }

    func testInvalidJournalPayloadAndDuplicateRawFailClosed() throws {
        for payload: [String: C.JSON] in [["useSleepStagerV2": .null], ["useMotionAwareWake": .number(1)],
            ["effortMethod": .string("guess")], ["hrvBaselineEpoch": .number(C.safeInteger + 1)],
            ["customHRZoneLowerBounds": .array([100, 90, 120, 130, 140].map { .number(Double($0)) })]] {
            var i = try S10Fixtures.input()
            i.journal[1] = S10Fixtures.journal(.config, 2, payload: payload)
            XCTAssertThrowsError(try V.validate(i))
        }
        var i = try S10Fixtures.input()
        S10Fixtures.append(&i, .hr, i.asOfExclusive - 1, ["bpm": .number(60)], id: "same")
        i.raw.append(i.raw[0])
        XCTAssertThrowsError(try V.validate(i))
        i.raw.removeLast(); i.historyCaseIds = [i.id]
        XCTAssertThrowsError(try V.validate(i))
    }
}
