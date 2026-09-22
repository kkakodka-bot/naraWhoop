import Foundation
import WhoopStore
import StrandImport

/// Health consumes authorized values and exact event bounds from the canonical ledger only.
/// Null/revoked families still produce replacement keys so old app-written values are removed.
enum CanonicalHealthWritebackPlan {
    // Skin temperature is not silently relabelled as HealthKit core body temperature.
    static let quantities = ["resting_hr_bpm", "hrv_sdnn_ms", "resp_rate_bpm", "spo2_pct"]
    struct Sleep: Decodable {
        struct Stage: Decodable {
            let start: Int64, end: Int64
            let stage: String
            let state: String?
            /// HealthKit has no unknown/off-body stage. Preserve the gap instead of guessing.
            var exportStage: String? {
                guard !["state_unknown", "off_body", "sleep_unstaged"].contains(state ?? "") else { return nil }
                return ["wake", "awake", "light", "deep", "rem"].contains(stage) ? stage : nil
            }
        }
        private let source: ServerScoreSleep
        let stages: [Stage]
        var id: String { source.id }
        var start: Int { source.start }
        var end: Int { source.end }
        var asleepMin: Double? { source.asleepMin }
        var efficiency: Double? { source.efficiency }
        var hrvRmssdMs: Double? { source.hrvRmssdMs }
        var restingHrBpm: Double? { source.restingHrBpm }
        private enum CodingKeys: String, CodingKey { case stages }
        init(from decoder: Decoder) throws {
            source = try ServerScoreSleep(from: decoder)
            stages = try decoder.container(keyedBy: CodingKeys.self).decode([Stage].self, forKey: .stages)
        }
        func validate() throws {
            guard UUID(uuidString: id) != nil, start >= 0, end > start, end - start <= 7 * 86400,
                  stages.count <= 10080,
                  [source.inBedMin, source.asleepMin, source.awakeMin, source.lightMin, source.deepMin,
                   source.remMin, source.efficiency, source.restingHrBpm, source.hrvRmssdMs]
                    .compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= Double(Int32.max) })
            else { throw ServerScoreDecodeError.invalid }
            var previousEnd = Int64(start)
            for segment in stages {
                guard ["wake", "awake", "light", "deep", "rem", "unknown", "sleep_unstaged", "off_body"].contains(segment.stage),
                      segment.state == nil || ["awake", "sleep", "sleep_unstaged", "state_unknown", "off_body"].contains(segment.state!),
                      segment.start >= previousEnd, segment.end > segment.start, segment.end <= Int64(end)
                else { throw ServerScoreDecodeError.invalid }
                previousEnd = segment.end
            }
        }
    }
    struct Day {
        let result: ServerCanonicalResults
        let quantities: [String: Double]
        let sleeps: [Sleep]
    }

    enum Unit: Equatable { case countPerMinute, milliseconds, fraction }
    enum StageValue: String { case inBed, awake, light, deep, rem }
    enum Payload: Equatable {
        case quantity(metric: String, value: Double, unit: Unit)
        case sleep(StageValue)
    }
    struct Record: Equatable {
        let payload: Payload
        let start: Date, end: Date
        let externalUUID: String
        let metadata: [String: String]
    }
    enum Target: Equatable {
        case quantity(metric: String, externalUUID: String)
        case sleep(day: String, accountNamespace: String)
    }
    struct Replacement: Equatable {
        let target: Target
        let records: [Record]
    }
    enum Operation: Equatable { case delete(Replacement), save([Record]) }

    static func replacements(state: ServerScoreViewState, accountNamespace: String,
                             now: Date = Date()) throws -> [Replacement] {
        let identifiers = ["resting_hr_bpm": "HKQuantityTypeIdentifierRestingHeartRate",
            "hrv_sdnn_ms": "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            "resp_rate_bpm": "HKQuantityTypeIdentifierRespiratoryRate",
            "spo2_pct": "HKQuantityTypeIdentifierOxygenSaturation"]
        var output: [Replacement] = []
        func scoped(_ key: String) -> String { "account:\(accountNamespace):\(key)" }
        for plan in try days(state: state) {
            let result = plan.result
            guard let ledger = CanonicalConsumerPublication.ledger(result, state: state),
                  CanonicalExport.isCurrent(ledger) else { continue }
            func metadata(_ family: String) throws -> [String: String] {
                guard let receipt = ledger.families[family] else { throw ServerScoreDecodeError.invalid }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                return ["com.frwhoop.account-namespace": accountNamespace,
                    "naraAccountNamespace": accountNamespace, "naraScoreDay": result.day,
                    "naraProject": result.project, "naraOwner": result.ownerID, "naraSource": result.sourceID,
                    "naraCanonicalDevice": result.deviceID,
                    "naraServerReadState": ledger.readState ?? "available",
                    "naraCanonicalResult": String(decoding: try encoder.encode(receipt), as: UTF8.self)]
            }
            for metric in quantities {
                guard let identifier = identifiers[metric], let family = result.result(for: metric) else { continue }
                let key = scoped(HealthWriteback.appleHealthVitalKey(metricId: identifier, day: result.day))
                var records: [Record] = []
                if let value = plan.quantities[metric], let through = family.observedThrough,
                   let at = ServerScoreDate.parse(through), at <= now,
                   let familyKey = ServerCanonicalResults.familyMetrics.first(where: { $0.value.contains(metric) })?.key {
                    let unit: Unit = metric == "spo2_pct" ? .fraction : (metric == "hrv_sdnn_ms" ? .milliseconds : .countPerMinute)
                    records.append(Record(payload: .quantity(metric: metric, value: metric == "spo2_pct" ? value / 100 : value, unit: unit),
                        start: at, end: at, externalUUID: key, metadata: try metadata(familyKey)))
                }
                output.append(Replacement(target: .quantity(metric: metric, externalUUID: key), records: records))
            }
            var records: [Record] = []
            for sleep in plan.sleeps {
                let key = scoped("server-sleep:\(sleep.id)"), meta = try metadata("sleep")
                func append(_ stage: StageValue, _ start: Int64, _ end: Int64) {
                    records.append(Record(payload: .sleep(stage),
                        start: Date(timeIntervalSince1970: Double(start)), end: Date(timeIntervalSince1970: Double(end)),
                        externalUUID: key, metadata: meta))
                }
                append(.inBed, Int64(sleep.start), Int64(sleep.end))
                for stage in sleep.stages {
                    guard let name = stage.exportStage,
                          let value = StageValue(rawValue: name == "wake" ? "awake" : name) else { continue }
                    append(value, stage.start, stage.end)
                }
            }
            output.append(Replacement(target: .sleep(day: result.day, accountNamespace: accountNamespace), records: records))
        }
        return output
    }

    @MainActor
    static func publish(_ replacements: [Replacement], authorized: (Target) -> Bool,
                        perform: (Operation) async throws -> Void) async throws {
        for replacement in replacements where authorized(replacement.target) {
            try await perform(.delete(replacement))
            if !replacement.records.isEmpty { try await perform(.save(replacement.records)) }
        }
    }
    static func days(state: ServerScoreViewState) throws -> [Day] {
        try state.canonicalDays.values.sorted { $0.day < $1.day }.compactMap { result in
            // A failed transport read must not be presented to Health as newly current physiology.
            // Existing historical Health samples keep their original immutable receipt.
            guard CanonicalConsumerPublication.ledger(result, state: state)?.permitsRead == true else { return nil }
            let values = Dictionary(uniqueKeysWithValues: quantities.compactMap { metric in
                result.result(for: metric)?.number(metric).map { (metric, $0) }
            })
            var sleeps: [Sleep] = []
            if let family = result.families["sleep"], family.status == "available", family.hasCanonicalAuthorization,
               let payload = family.values["sleep_sessions"], payload != .null {
                // Fail the export on a malformed session contract; never substitute empty DTOs.
                sleeps = try JSONDecoder().decode([Sleep].self, from: JSONEncoder().encode(payload))
                try sleeps.forEach { try $0.validate() }
            }
            return Day(result: result, quantities: values, sleeps: sleeps)
        }
    }
}
