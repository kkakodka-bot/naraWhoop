import Foundation
import WhoopProtocol
@testable import StrandAnalytics

enum ServerDaySwiftV3Contract {
    typealias C = ServerDaySwiftContract
    typealias JSON = C.JSON
    typealias Stream = C.Stream
    typealias RawRow = C.RawRow
    static let schemaVersion = 2
    static let recipe = "w4-server-day-v1"
    static let rowLimit = 300_000

    struct Source: Codable, Equatable {
        let externalDeviceId: String
        let registryFamily: String?
        let storeModel: String
        let storeBrand: String

        enum CodingKeys: String, CodingKey { case externalDeviceId, registryFamily, storeModel, storeBrand }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(externalDeviceId, forKey: .externalDeviceId)
            try c.encode(registryFamily, forKey: .registryFamily)
            try c.encode(storeModel, forKey: .storeModel)
            try c.encode(storeBrand, forKey: .storeBrand)
        }
    }

    struct Input: Codable, Equatable {
        var schemaVersion = ServerDaySwiftV3Contract.schemaVersion
        var recipe = ServerDaySwiftV3Contract.recipe
        var id: String
        var identity: C.Identity
        var source: Source
        var day: String
        var timezone: String
        var asOfExclusive: Int
        var raw: [RawRow] = []
        var journal: [C.JournalRow] = []
        var historyCaseIds: [String] = []

        var historyInput: C.Input {
            C.Input(identity: identity, day: day, timezone: timezone, raw: raw, journal: journal)
        }
    }

    struct Bounds: Codable, Equatable {
        let dayLo: Int
        let dayHi: Int
        let nightLo: Int
        let nightHi: Int
        let tzOffsetSeconds: Int
        var dayRange: Range<Int> { dayLo..<(dayHi + 1) }
    }

    struct StoredIdentity: Codable, Equatable {
        let id: String
        let rowid: Int64
        let ts: Int
        let fields: [String: JSON]
    }

    struct RRPolicy: Codable, Equatable {
        let adapter: String
        let canonicalOnly: Bool
        let canonicalChannel: Int?
        let windowHasModern: Bool
        let shippedStoreCanonicalOnly: Bool
        let shippedStoreIDs: [String]
        let serverWindowIDs: [String]
    }

    struct Selection: Codable, Equatable {
        let bounds: Bounds
        let streams: [String: [StoredIdentity]]
        let dayHr: [String]
        let daySteps: [String]
        let dayGravity: [String]
        let vendorResp: [String]
        let scoringResp: [String]
        let stepPredecessor: String?
        let rrPolicy: RRPolicy
        let gaps: [String]
        let retainedByOwner: [String: [String: Int]]
        let profileRevision: Int64
        let configurationRevision: Int64
        let effectiveProfile: [String: JSON]
        let effectiveConfig: [String: JSON]
    }

    static let fields: [Stream: (required: Set<String>, optional: Set<String>)] = [
        .hr: (["bpm"], []), .rr: (["rrMs", "seq"], ["ord", "srcChannel", "tsSuspect"]),
        .resp: (["raw"], []), .gravity: (["x", "y", "z"], ["dynAccel"]),
        .events: (["kind", "payloadJSON"], []), .steps: (["counter"], ["activityClass", "provenance"]),
        .skinTemp: (["raw"], ["aux1Raw", "aux2Raw"]), .spo2: (["red", "ir"], []),
        .bandState: (["state"], ["rawByte", "provenance"]), .ppgHr: (["bpm"], ["conf", "provenance"])
    ]

    static func decode(_ bytes: Data) throws -> Input {
        let json = try JSONDecoder().decode(JSON.self, from: bytes)
        let root = try object(json)
        try keys(root, required: "schemaVersion recipe id identity source day timezone asOfExclusive raw journal historyCaseIds")
        let identity = try object(root["identity"]!)
        try keys(identity, required: "userId sourceDeviceId algorithmVersion")
        let source = try object(root["source"]!)
        try keys(source, required: "externalDeviceId registryFamily storeModel storeBrand")
        if source["registryFamily"] != .null { _ = try string(source["registryFamily"]) }
        for row in try array(root["raw"]!) {
            try keys(object(row), required: "id userId sourceDeviceId stream ts fields")
        }
        for row in try array(root["journal"]!) {
            try keys(object(row), required: "userId sourceDeviceId kind entity revision effectiveDay deleted payload")
        }
        try safeNumbers(json)
        let input = try JSONDecoder().decode(Input.self, from: bytes)
        _ = try validate(input)
        return input
    }

    @discardableResult static func validate(_ input: Input) throws -> Bounds {
        guard input.schemaVersion == schemaVersion, input.recipe == recipe,
              !input.id.isEmpty, input.id.utf8.count <= 128,
              !input.identity.algorithmVersion.isEmpty, !input.source.externalDeviceId.isEmpty,
              input.raw.count <= rowLimit * Stream.allCases.count,
              input.journal.count <= 10_000, input.historyCaseIds.count <= 400,
              Set(input.historyCaseIds).count == input.historyCaseIds.count,
              !input.historyCaseIds.contains(input.id) else { throw failure("input") }
        let day = try C.dayBounds(input.day, input.timezone)
        guard input.asOfExclusive == day.upperBound else { throw failure("intraday_unsupported") }
        let zone = TimeZone(identifier: input.timezone)!
        let bounds = Bounds(dayLo: day.lowerBound, dayHi: day.upperBound - 1,
            nightLo: day.lowerBound - 30 * 3_600, nightHi: day.upperBound - 1,
            tzOffsetSeconds: zone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(day.lowerBound))))
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        for row in input.raw {
            try safeNumbers(.object(row.fields))
            let ownerStream = "\(row.userId)/\(row.sourceDeviceId)/\(row.stream.rawValue)"
            counts[ownerStream, default: 0] += 1
            guard !row.id.isEmpty, row.ts >= 0, row.ts <= 253_402_300_799,
                  seen.insert(ownerStream + "/" + row.id).inserted,
                  counts[ownerStream]! <= rowLimit else { throw failure("raw_identity_or_limit") }
            let shape = fields[row.stream]!
            guard shape.required.isSubset(of: Set(row.fields.keys)),
                  Set(row.fields.keys).isSubset(of: shape.required.union(shape.optional)) else { throw failure("raw_fields") }
            for (key, value) in row.fields {
                if value == .null, shape.optional.contains(key) { continue }
                switch key {
                case "kind", "payloadJSON": _ = try string(value)
                case "provenance": _ = try object(value); try safeNumbers(value)
                case "x", "y", "z", "dynAccel", "conf": _ = try number(value)
                default: _ = try integer(value)
                }
            }
        }
        for row in input.journal {
            guard row.revision > 0, Double(row.revision) <= C.safeInteger else { throw failure("revision") }
            try safeNumbers(.object(row.payload))
            if !row.deleted, row.kind == .profile || row.kind == .config { try validatePayload(row) }
        }
        _ = try C.resolve(input.historyInput)
        return bounds
    }

    private static func validatePayload(_ row: C.JournalRow) throws {
        let p = row.payload
        guard p["schemaVersion"] == .number(1) else { throw failure("payload_version") }
        if row.kind == .profile {
            try keys(p, required: "schemaVersion timezone", optional: "age sex weightKg heightCm waistCm stepTicksPerStep")
            guard TimeZone(identifier: try string(p["timezone"])) != nil else { throw failure("profile_zone") }
            if let sex = p["sex"], sex != .null {
                guard ["male", "female", "nonbinary"].contains(try string(sex)) else { throw failure("sex") }
            }
            for key in ["age", "weightKg", "heightCm", "waistCm", "stepTicksPerStep"] {
                if let value = p[key], value != .null {
                    let n = try number(value)
                    guard n > 0, n <= 500 else { throw failure("profile_number") }
                }
            }
        } else {
            try keys(p, required: "schemaVersion", optional: "maxHR effortMethod deepHrvWindow useSleepStagerV2 useMotionAwareWake sleepNeedHours hrvBaselineEpoch recoveryBaselineEpoch sourceEra journalContextEnabled cycleAwarenessEnabled daytimePersonalBaselineEnabled customHRZoneLowerBounds stepsManualCoefficient spo2CandidateDisplayEnabled dayCycleMode")
            for key in ["deepHrvWindow", "useSleepStagerV2", "useMotionAwareWake", "journalContextEnabled", "cycleAwarenessEnabled", "daytimePersonalBaselineEnabled", "spo2CandidateDisplayEnabled"] {
                if let v = p[key] { guard case .bool = v else { throw failure("config_boolean") } }
            }
            for key in ["maxHR", "sleepNeedHours", "hrvBaselineEpoch", "recoveryBaselineEpoch", "stepsManualCoefficient"] {
                if let v = p[key], v != .null {
                    let n = try number(v)
                    guard n >= 0, n <= C.safeInteger else { throw failure("config_number") }
                    if key == "maxHR", !(80...240).contains(n) { throw failure("maxHR") }
                    if key == "sleepNeedHours", !(3...14).contains(n) { throw failure("sleepNeedHours") }
                    if key == "stepsManualCoefficient", n > 1_000_000 { throw failure("step_coefficient") }
                }
            }
            if let v = p["effortMethod"], !["EDWARDS", "BANISTER"].contains(try string(v)) { throw failure("effort") }
            if let v = p["dayCycleMode"], !["midnight", "sleep_onset"].contains(try string(v)) { throw failure("cycle") }
            if let v = p["sourceEra"] {
                let s = try string(v)
                guard !s.isEmpty, s.count <= 128 else { throw failure("era") }
            }
            if let v = p["customHRZoneLowerBounds"], v != .null {
                let xs = try array(v).map(number)
                guard xs.count == 5, xs.allSatisfy({ (30...250).contains($0) }),
                      zip(xs, xs.dropFirst()).allSatisfy({ $0 < $1 }) else { throw failure("zones") }
            }
        }
    }

    static func failure(_ message: String) -> C.Failure { .invalid("s10:" + message) }
    static func object(_ value: JSON) throws -> [String: JSON] {
        guard case .object(let o) = value else { throw failure("object") }; return o
    }
    static func array(_ value: JSON) throws -> [JSON] {
        guard case .array(let a) = value else { throw failure("array") }; return a
    }
    static func number(_ value: JSON?) throws -> Double {
        guard case .number(let n) = value, n.isFinite else { throw failure("number") }; return n
    }
    static func integer(_ value: JSON?) throws -> Int {
        let n = try number(value)
        guard n.rounded(.towardZero) == n, abs(n) <= C.safeInteger, let i = Int(exactly: n) else { throw failure("integer") }
        return i
    }
    static func string(_ value: JSON?) throws -> String {
        guard case .string(let s) = value else { throw failure("string") }; return s
    }
    static func keys(_ object: [String: JSON], required: String, optional: String = "") throws {
        let requiredKeys = Set(required.split(separator: " ").map(String.init))
        let allowed = requiredKeys.union(optional.split(separator: " ").map(String.init))
        guard requiredKeys.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: allowed) else { throw failure("keys") }
    }
    static func safeNumbers(_ value: JSON) throws {
        switch value {
        case .number(let n): guard n.isFinite, abs(n) <= C.safeInteger else { throw failure("safe_number") }
        case .array(let a): for v in a { try safeNumbers(v) }
        case .object(let o): for v in o.values { try safeNumbers(v) }
        default: break
        }
    }
    static func json<T: Encodable>(_ value: T) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: C.bytes(value))
    }
}
