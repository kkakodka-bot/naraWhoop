import Foundation
import StrandAnalytics

/// Converts complete emitted context evidence only. These adapters never run an engine or emit alerts.
enum ServerScoreContextPresentation {
    static func cycle(day: String, state: ServerScoreViewState) -> CyclePhaseEngine.Result? {
        guard let snapshot = supported(.cyclePhase, day: day, state: state),
              let value = snapshot.details?.cycle,
              value.baselinePolicy == "pre_observation_absolute_temperature",
              let phase = CyclePhaseEngine.Phase(rawValue: value.phase),
              let confidence = CyclePhaseEngine.Confidence(rawValue: value.confidence),
              let note = value.note else { return nil }
        return .init(phase: phase, confidence: confidence, cycleDayLow: value.cycleDayLow,
            cycleDayHigh: value.cycleDayHigh, cycleLengthDays: value.cycleLengthDays,
            nextPeriodWindow: value.nextPeriodWindow.map {
                .init(earliestDay: $0.earliestDay, latestDay: $0.latestDay)
            }, shiftMarkers: value.shiftMarkers.map { .init(day: $0) }, note: note)
    }

    static func circadian(day: String, state: ServerScoreViewState) -> CircadianEngine.PhaseEstimate? {
        // Neither independent scalar may be filled from a local model or a default wake time.
        guard state.owns(.circadianOffset),
              let snapshot = supported(.circadianPhase, day: day, state: state),
              snapshot.metrics?[ServerScoreMetric.circadianPhase.rawValue]?.unit == "local_hour",
              snapshot.metrics?[ServerScoreMetric.circadianOffset.rawValue]?.unit == "min",
              let minimum = snapshot.value(.circadianPhase), (0..<24).contains(minimum),
              let offset = snapshot.value(.circadianOffset), (-720...720).contains(offset),
              let value = snapshot.details?.circadian,
              let confidence = CircadianEngine.PhaseConfidence(rawValue: value.confidence),
              let note = value.note else { return nil }
        return .init(tempMinHour: minimum, acrophaseHours: value.acrophaseHours,
            offsetVsScheduleMinutes: offset, confidence: confidence, note: note)
    }

    static func illness(day: String, state: ServerScoreViewState) -> IllnessSignalEngine.Result? {
        guard let snapshot = supported(.illnessScore, day: day, state: state),
              snapshot.metrics?[ServerScoreMetric.illnessScore.rawValue]?.unit == "score_0_100",
              let score = snapshot.value(.illnessScore), (0...100).contains(score),
              let value = snapshot.details?.illness,
              let level = IllnessSignalEngine.Level(rawValue: value.level),
              let fired = value.firedSignals, let copy = value.copy else { return nil }
        return .init(score: score, level: level, firedSignals: fired, suppressedBy: value.suppressedBy,
            signalCount: value.signalCount, copy: copy)
    }

    /// Independent of illness-score ownership. The distance result is evidence, never an alert gate.
    /// Legacy partial evidence stays unavailable; neither feature count nor fallback can be inferred.
    static func illnessDistance(day: String, state: ServerScoreViewState) -> IllnessDistance.Result? {
        guard let snapshot = supported(.illnessDistance, day: day, state: state),
              snapshot.schemaVersion == 2,
              let reading = snapshot.metrics?[ServerScoreMetric.illnessDistance.rawValue],
              reading.unit == "dimensionless", reading.method == "IllnessDistance_identity_correlation",
              reading.status == nil || reading.status == "available",
              let distance = reading.value, distance.isFinite, distance >= 0,
              let value = snapshot.details?.illness, value.wellnessOnly, !value.distanceIsAlertGate,
              let count = value.distanceDeviatingFeatures, (0...4).contains(count),
              let fallback = value.distanceUsedDiagonalFallback else { return nil }
        return .init(distance: distance, deviatingFeatures: count, fires: value.distanceFires,
                     usedDiagonalFallback: fallback)
    }

    private static func supported(_ metric: ServerScoreMetric, day: String,
                                  state: ServerScoreViewState) -> ServerScoreSnapshot? {
        guard let snapshot = ServerScoreDisplay.detailSnapshot(metric, day: day, state: state),
              snapshot.details?.contextPolicy == "as-of-context-v1" else { return nil }
        return snapshot
    }
}
