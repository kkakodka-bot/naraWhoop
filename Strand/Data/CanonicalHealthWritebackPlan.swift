import Foundation
import WhoopStore

/// Health consumes authorized values and exact event bounds from the canonical ledger only.
/// Null/revoked families still produce replacement keys so old app-written values are removed.
enum CanonicalHealthWritebackPlan {
    // Skin temperature is not silently relabelled as HealthKit core body temperature.
    static let quantities = ["resting_hr_bpm", "hrv_sdnn_ms", "resp_rate_bpm", "spo2_pct"]
    struct Day {
        let result: ServerCanonicalResults
        let quantities: [String: Double]
        let sleeps: [ServerScoreSleep]
    }
    static func days(state: ServerScoreViewState) throws -> [Day] {
        try state.canonicalDays.values.sorted { $0.day < $1.day }.compactMap { result in
            // A failed transport read must not be presented to Health as newly current physiology.
            // Existing historical Health samples keep their original immutable receipt.
            guard CanonicalConsumerPublication.ledger(result, state: state)?.permitsRead == true else { return nil }
            let values = Dictionary(uniqueKeysWithValues: quantities.compactMap { metric in
                result.result(for: metric)?.number(metric).map { (metric, $0) }
            })
            var sleeps: [ServerScoreSleep] = []
            if let family = result.families["sleep"], family.status == "available", family.hasCanonicalAuthorization,
               let payload = family.values["sleep_sessions"], payload != .null {
                // Fail the export on a malformed session contract; never substitute empty DTOs.
                sleeps = try JSONDecoder().decode([ServerScoreSleep].self, from: JSONEncoder().encode(payload))
                try sleeps.forEach { try $0.validate() }
            }
            return Day(result: result, quantities: values, sleeps: sleeps)
        }
    }
}
