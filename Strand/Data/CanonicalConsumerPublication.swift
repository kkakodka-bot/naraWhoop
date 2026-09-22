import Foundation
import WhoopStore
import StrandDesign

/// All background consumers capture this same immutable day, never a widget-specific score anchor.
enum CanonicalConsumerPublication {
    static func day(in state: ServerScoreViewState, now: Date = Date()) -> String {
        if !state.currentDay.isEmpty { return state.currentDay }
        return ServerScoreDate.day(now, timeZone: TimeZone(identifier: state.timezone) ?? .current)
    }

    static func ledger(_ result: ServerCanonicalResults?) -> CanonicalConsumerLedger? {
        guard let result else { return nil }
        return CanonicalConsumerLedger(project: result.project, ownerID: result.ownerID,
            sourceID: result.sourceID, deviceID: result.deviceID, window: result.day,
            families: result.families.mapValues { family in
                CanonicalConsumerLedger.Receipt(
                    family: ServerCanonicalResults.familyMetrics.first { $0.value == Set(family.metrics) }?.key ?? "",
                    status: family.status, reason: family.reason, algorithmVersion: family.algorithmVersion,
                    configurationVersion: family.configurationVersion, modelVersion: family.modelVersion,
                    preprocessingVersion: family.preprocessingVersion, qualityVersion: family.qualityVersion,
                    inputRevision: family.inputRevision, resultRevision: family.resultRevision,
                    computedAt: family.computedAt, observedThrough: family.observedThrough,
                    freshness: family.freshness, timezoneID: family.timezoneID,
                    manifestHash: family.manifestHash, featureManifestHash: family.featureManifestHash,
                    canonicalAuthorization: family.canonicalQualification)
            })
    }

    static func value(_ metric: String, in result: ServerCanonicalResults?) -> Double? {
        result?.result(for: metric)?.number(metric)
    }
}
