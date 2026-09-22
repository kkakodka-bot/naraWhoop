import Foundation
@testable import StrandAnalytics

/// Literal expected DTO projection for legacy coarse-RR fixtures. No scoring functions are called.
/// Sensor-pipeline qualification deliberately removed unverified HRV and added sleep provenance.
enum W4QualifiedSessionFixture {
    static func session(_ source: SleepSession, episode: String, groupStart: Int? = nil,
                        boundary: String = "detected_candidate") -> SleepSession {
        let stages = source.stages.isEmpty ? [StageSegment(start: source.start, end: source.end,
            stage: "unknown", state: "state_unknown", evidenceCoverage: 0,
            abstentionReason: "no_epoch_observations", computationMode: "retrospective",
            algorithmVersion: "sleep-evidence-v2", probabilitiesCalibrated: false)] : source.stages
        return SleepSession(start: source.start, end: source.end, efficiency: source.efficiency,
            stages: stages, restingHR: source.restingHR, avgHRV: nil, hrOnly: source.hrOnly,
            episodeType: episode, groupedNightId: groupStart.map { "sleep-group:\($0)" },
            boundaryProvenance: boundary, denominatorKind: "estimated_sleep_opportunity")
    }
}
