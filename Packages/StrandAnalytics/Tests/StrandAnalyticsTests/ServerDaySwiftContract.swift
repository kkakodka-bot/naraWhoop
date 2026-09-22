import CryptoKit
import Foundation
@testable import StrandAnalytics

/// Test-only history boundary. This is not a full server_day result or a corpus exporter.
enum ServerDaySwiftContract {
    static let schemaVersion = 2
    static let recipe = "w4-server-day-v1"
    static let safeInteger = 9_007_199_254_740_991.0

    enum Failure: Error, Equatable {
        case invalid(String)
    }

    enum JSON: Codable, Equatable {
        case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([JSON].self) { self = .array(v) }
            else { self = .object(try c.decode([String: JSON].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
            }
        }
    }

    struct Identity: Codable, Equatable {
        let userId: UUID
        let sourceDeviceId: UUID
        let algorithmVersion: String
    }

    enum Kind: String, Codable, CaseIterable {
        case profile, config, sleepEdit = "sleep_edit", context, period
        case importedDaily = "imported_daily", manualWorkout = "manual_workout"
    }

    struct JournalRow: Codable, Equatable {
        let userId: UUID
        let sourceDeviceId: UUID
        let kind: Kind
        let entity: String
        let revision: Int64
        let effectiveDay: String
        let deleted: Bool
        let payload: [String: JSON]
    }

    enum Stream: String, Codable, CaseIterable {
        case hr, rr, resp, gravity, events, steps, skinTemp, spo2, bandState, ppgHr
    }

    /// Values and provenance are retained verbatim. This increment does not implement RR selection.
    struct RawRow: Codable, Equatable {
        let id: String
        let userId: UUID
        let sourceDeviceId: UUID
        let stream: Stream
        let ts: Int
        let fields: [String: JSON]
    }

    struct Input: Codable, Equatable {
        var schemaVersion = ServerDaySwiftContract.schemaVersion
        var recipe = ServerDaySwiftContract.recipe
        let identity: Identity
        let day: String
        let timezone: String
        var raw: [RawRow] = []
        var journal: [JournalRow] = []
    }

    struct Resolution: Equatable {
        let dayBounds: Range<Int>
        let nightBounds: Range<Int>
        let rows: [JournalRow]
        let raw: [RawRow]

        func head(_ kind: Kind, _ entity: String = "primary") -> JournalRow? {
            rows.first { $0.kind == kind && $0.entity == entity }
        }
        func payload(_ kind: Kind) -> [String: JSON] {
            guard let row = head(kind), !row.deleted else { return [:] }
            return row.payload
        }
    }

    struct Policy: Codable, Equatable {
        let sourceEra: String
        let hrvEpoch: Double
        let recoveryEpoch: Double
        let effortMethod: String

        func epoch(_ key: String) -> Double {
            ["hrv", "readiness_hrv_ln"].contains(key) ? hrvEpoch : recoveryEpoch
        }
    }

    static func resolve(_ input: Input) throws -> Resolution {
        guard input.schemaVersion == schemaVersion, input.recipe == recipe,
              !input.identity.algorithmVersion.isEmpty else { throw Failure.invalid("contract") }
        let bounds = try dayBounds(input.day, input.timezone)
        let night = (bounds.lowerBound - 30 * 3_600)..<bounds.upperBound
        var revisions = Set<Int64>()
        var heads: [String: JournalRow] = [:]
        for row in input.journal where row.userId == input.identity.userId && row.sourceDeviceId == input.identity.sourceDeviceId {
            _ = try dayBounds(row.effectiveDay, "UTC")
            guard row.revision > 0, Double(row.revision) <= safeInteger, revisions.insert(row.revision).inserted,
                  !row.entity.isEmpty else { throw Failure.invalid("journal_identity") }
            guard row.deleted ? row.payload.isEmpty : row.payload["schemaVersion"] == .number(1) else {
                throw Failure.invalid("journal_payload_envelope")
            }
            if row.kind == .profile || row.kind == .config {
                guard row.entity == "primary" else { throw Failure.invalid("primary_entity") }
            }
            guard row.effectiveDay <= input.day else { continue }
            let key = row.kind.rawValue + ":" + row.entity
            let revisionFirst = row.kind == .sleepEdit || row.kind == .manualWorkout
            if let previous = heads[key] {
                let newer = revisionFirst || row.effectiveDay == previous.effectiveDay
                    ? row.revision > previous.revision : row.effectiveDay > previous.effectiveDay
                if !newer { continue }
            }
            heads[key] = row
        }
        var identities = Set<String>()
        let raw = try input.raw.filter {
            $0.userId == input.identity.userId && $0.sourceDeviceId == input.identity.sourceDeviceId
        }.map { row -> RawRow in
            guard !row.id.isEmpty, abs(Double(row.ts)) <= safeInteger,
                  identities.insert(row.stream.rawValue + ":" + row.id).inserted else {
                throw Failure.invalid("raw_identity")
            }
            return row
        }.filter { night.contains($0.ts) }.sorted {
            if $0.ts != $1.ts { return $0.ts < $1.ts }
            if $0.stream != $1.stream { return $0.stream.rawValue < $1.stream.rawValue }
            return $0.id < $1.id
        }
        let result = Resolution(dayBounds: bounds, nightBounds: night,
            rows: heads.values.sorted { ($0.kind.rawValue, $0.entity) < ($1.kind.rawValue, $1.entity) }, raw: raw)
        let profile = result.payload(.profile)
        if let zone = try string(profile, "timezone") {
            guard zone == input.timezone else { throw Failure.invalid("profile_timezone_mismatch") }
        }
        return result
    }

    static func policy(_ resolution: Resolution, identity: Identity) throws -> Policy {
        let config = resolution.payload(.config)
        let method = try string(config, "effortMethod") ?? "EDWARDS"
        let era = try string(config, "sourceEra") ?? identity.sourceDeviceId.uuidString.lowercased()
        let hrv = try number(config, "hrvBaselineEpoch") ?? 0
        let recovery = try number(config, "recoveryBaselineEpoch") ?? 0
        guard !era.isEmpty, ["EDWARDS", "BANISTER"].contains(method), hrv >= 0, recovery >= 0,
              hrv <= safeInteger, recovery <= safeInteger else { throw Failure.invalid("policy") }
        return Policy(sourceEra: era, hrvEpoch: hrv, recoveryEpoch: recovery, effortMethod: method)
    }

    static func number(_ object: [String: JSON], _ key: String) throws -> Double? {
        guard let value = object[key] else { return nil }
        if value == .null { return nil }
        guard case .number(let n) = value, n.isFinite else { throw Failure.invalid("number:\(key)") }
        return n
    }

    static func string(_ object: [String: JSON], _ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        guard case .string(let s) = value else { throw Failure.invalid("string:\(key)") }
        return s
    }

    static func dayBounds(_ day: String, _ timezone: String) throws -> Range<Int> {
        guard let zone = TimeZone(identifier: timezone) else { throw Failure.invalid("timezone") }
        return try DayCycleResolver.localDayBounds(day: day, timezone: zone)
    }

    static func dayKey(_ timestamp: Int, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(timestamp)))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func days(from: String, through: String) throws -> [String] {
        let first = try dayBounds(from, "UTC").lowerBound
        let last = try dayBounds(through, "UTC").lowerBound
        guard first <= last else { return [] }
        return stride(from: first, through: last, by: 86_400).map { dayKey($0, zone: TimeZone(secondsFromGMT: 0)!) }
    }

    static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try bytes(value)).map { String(format: "%02x", $0) }.joined()
    }
}
