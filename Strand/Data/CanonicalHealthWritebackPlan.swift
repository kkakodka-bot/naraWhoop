import Foundation
import WhoopStore

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
