import Foundation
import WhoopStore
import StrandDesign

/// All background consumers capture this same immutable day, never a widget-specific score anchor.
enum CanonicalConsumerPublication {
    static func widgetSnapshot(state: ServerScoreViewState, accountNamespace: String,
                               heartRate: Int?, batteryPct: Int?, bonded: Bool,
                               now: Date = Date()) -> WidgetSnapshot {
        let result = state.canonicalDays[day(in: state, now: now)]
        func rounded(_ metric: String) -> Int? {
            value(metric, in: result, state: state).map { Int($0.rounded()) }
        }
        let insight = result?.result(for: "insights")
        let text: String?
        if ledger(result, state: state)?.permitsRead == true,
           let insight, insight.hasCanonicalAuthorization, insight.status == "available",
           case .string(let content) = insight.values["insights"] { text = content }
        else { text = nil }
        return WidgetSnapshot(recovery: rounded("recovery"), bpm: heartRate, batteryPct: batteryPct,
            bonded: bonded, updated: now, effort: rounded("strain"), rest: rounded("sleep_performance"),
            hrv: rounded("hrv_rmssd_ms"), restingHr: rounded("resting_hr_bpm"),
            accountNamespace: accountNamespace, finalHosted: true,
            canonicalLedger: ledger(result, state: state), insights: text)
    }

    static func watchSnapshot(state: ServerScoreViewState, accountNamespace: String?,
                              heartRate: Int?, now: Date = Date()) -> WatchScoreSnapshot {
        let window = day(in: state, now: now), result = state.canonicalDays[window]
        return WatchScoreSnapshot(charge: value("recovery", in: result, state: state),
            chargeCalibrating: false, effort: value("strain", in: result, state: state),
            effortCalibrating: false, rest: value("sleep_performance", in: result, state: state),
            restCalibrating: false, hr: heartRate, sleepSummary: "", asOf: now,
            scoreDay: window, accountNamespace: accountNamespace,
            finalHosted: true, canonicalLedger: ledger(result, state: state))
    }

    static func day(in state: ServerScoreViewState, now: Date = Date()) -> String {
        if !state.currentDay.isEmpty { return state.currentDay }
        return ServerScoreDate.day(now, timeZone: TimeZone(identifier: state.timezone) ?? .current)
    }

    static func ledger(_ result: ServerCanonicalResults?, state: ServerScoreViewState? = nil) -> CanonicalConsumerLedger? {
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
                    canonicalAuthorization: family.canonicalQualification, expiresAt: family.expiresAt)
            }, readState: state?.days[result.day]?.phase.rawValue, cached: state?.days[result.day]?.cached)
    }

    static func value(_ metric: String, in result: ServerCanonicalResults?, state: ServerScoreViewState? = nil) -> Double? {
        guard ledger(result, state: state)?.permitsRead != false else { return nil }
        return result?.result(for: metric)?.number(metric)
    }
}
