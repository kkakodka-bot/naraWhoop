import Foundation
import NoopPush

struct ScoringAlgorithmChoices: Sendable, Equatable {
    let banisterEffortEnabled: Bool
    let useSleepStagerV2: Bool
    let useMotionAwareWake: Bool
    let daytimePersonalBaselineEnabled: Bool
    let spo2CandidateDisplayEnabled: Bool
    var effortMethod: String { banisterEffortEnabled ? "BANISTER" : "EDWARDS" }
}

struct ScoringPreferenceSnapshot: Sendable, Equatable {
    enum Provenance: Sendable, Equatable { case accountLegacy, localOnly, serverCoupled }
    struct Consent: Sendable, Equatable {
        let journalEnabled: Bool
        let cycleEnabled: Bool
    }
    let context: AccountSessionContext
    private(set) var position: ScoringPreferencePosition
    private(set) var values: [ScoringPreferenceKey: ScoringPreferenceValue]
    private(set) var provenance: [ScoringPreferenceKey: Provenance]
    private let defaultDOB: Date

    static func seed(context: AccountSessionContext, domain: [String: Any], now: Date = Date()) -> Self {
        let dob = Calendar.current.date(byAdding: .year, value: -30, to: now) ?? now
        var values: [ScoringPreferenceKey: ScoringPreferenceValue] = [:]
        for key in ScoringPreferenceKey.allCases {
            guard let raw = domain[defaultsKey(key)] else { continue }
            let value: ScoringPreferenceValue?
            switch key {
            case .dateOfBirth:
                value = (raw as? Date).map { .number($0.timeIntervalSince1970) }
            case .hrZoneThresholds:
                if let text = raw as? String {
                    let parts = text.split(separator: ",")
                    let numbers = parts.compactMap { Int($0) }
                    value = numbers.count == parts.count ? .integers(numbers) : nil
                } else { value = nil }
            case .effortMethod:
                value = boolean(raw).map { .text($0 ? "BANISTER" : "EDWARDS") }
            case .ageExplicit, .useSleepStagerV2, .useMotionAwareWake, .daytimePersonalBaselineEnabled, .spo2CandidateDisplayEnabled:
                value = boolean(raw).map(ScoringPreferenceValue.boolean)
            case .sex, .hrvWindow:
                value = (raw as? String).map(ScoringPreferenceValue.text)
            default:
                if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    value = .number(number.doubleValue)
                } else { value = nil }
            }
            if let value, (try? value.validate(for: key)) != nil { values[key] = value }
        }
        // The legacy account age is a local seed, never a newly completed action.
        if values[.dateOfBirth] == nil, let age = domain["profile.age"] as? Int,
           (0...130).contains(age), let date = Calendar.current.date(byAdding: .year, value: -age, to: now) {
            values[.dateOfBirth] = .number(date.timeIntervalSince1970)
        }
        return Self(context: context, position: .initial, values: values,
                    provenance: values.mapValues { _ in .accountLegacy }, defaultDOB: dob)
    }

    private static func boolean(_ raw: Any) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    func restoring(_ projection: ScoringPreferenceProjection) throws -> Self {
        guard projection.scope == context.scope else { throw ScoringInputJournal.Failure.wrongOwner }
        var next = self
        for entry in projection.entries {
            try entry.value.validate(for: entry.key)
            next.values[entry.key] = entry.value
            next.provenance[entry.key] = entry.disposition == .localOnly ? .localOnly : .serverCoupled
        }
        next.position = projection.position
        return next
    }

    func applying(_ patch: [ScoringPreferenceIntent.Patch], position: ScoringPreferencePosition,
                  disposition: ScoringPreferenceIntent.Disposition) throws -> Self {
        guard !patch.isEmpty, patch.count <= ScoringPreferenceKey.allCases.count,
              Set(patch.map(\.key)).count == patch.count else { throw ScoringInputJournal.Failure.invalidInput }
        var next = self
        for item in patch {
            try item.value.validate(for: item.key)
            next.values[item.key] = item.value
            next.provenance[item.key] = disposition == .localOnly ? .localOnly : .serverCoupled
        }
        next.position = position
        return next
    }

    func number(_ key: ScoringPreferenceKey, default fallback: Double) -> Double {
        if case .number(let value) = values[key] { return value }; return fallback
    }
    func text(_ key: ScoringPreferenceKey, default fallback: String) -> String {
        if case .text(let value) = values[key] { return value }; return fallback
    }
    func flag(_ key: ScoringPreferenceKey, default fallback: Bool) -> Bool {
        if case .boolean(let value) = values[key] { return value }; return fallback
    }
    func hasOverride(_ key: ScoringPreferenceKey) -> Bool { values[key] != nil && values[key] != .clear }
    var dateOfBirth: Date { Date(timeIntervalSince1970: number(.dateOfBirth, default: defaultDOB.timeIntervalSince1970)) }
    var ageExplicit: Bool { flag(.ageExplicit, default: false) }
    var sex: String { text(.sex, default: "male") }
    var weightKg: Double { number(.weightKg, default: 75) }
    var heightCm: Double { number(.heightCm, default: 178) }
    var waistCm: Double { number(.waistCm, default: 0) }
    var hrMaxOverride: Int { Int(number(.hrMaxOverride, default: 0)) }
    var hrZoneThresholds: [Int] { if case .integers(let values) = values[.hrZoneThresholds] { return values }; return [] }
    var stepTicksPerStep: Double { number(.stepTicksPerStep, default: 1) }
    var stepsManualCoefficient: Double { number(.stepsManualCoefficient, default: 0) }
    var hrvWindowRaw: String { text(.hrvWindow, default: "whole") }
    var hrvBaselineEpoch: Double { number(.hrvBaselineEpoch, default: 0) }
    var recoveryBaselineEpoch: Double { number(.recoveryBaselineEpoch, default: 0) }
    var algorithmChoices: ScoringAlgorithmChoices {
        .init(banisterEffortEnabled: text(.effortMethod, default: "EDWARDS") == "BANISTER",
              useSleepStagerV2: flag(.useSleepStagerV2, default: true),
              useMotionAwareWake: flag(.useMotionAwareWake, default: false),
              daytimePersonalBaselineEnabled: flag(.daytimePersonalBaselineEnabled, default: false),
              spo2CandidateDisplayEnabled: flag(.spo2CandidateDisplayEnabled, default: true))
    }

    func payloads(at date: Date, timezone: String, consent: Consent) throws -> (profile: Data, config: Data) {
        guard let zone = TimeZone(identifier: timezone) else { throw ScoringInputJournal.Failure.invalidInput }
        var calendar = Calendar.current; calendar.timeZone = zone
        let age = calendar.dateComponents([.year], from: dateOfBirth, to: date).year ?? 0
        var profile: [String: Any] = ["schemaVersion": 1, "timezone": timezone]
        if ageExplicit { profile["age"] = age }
        if hasOverride(.sex) { profile["sex"] = sex }
        if hasOverride(.weightKg) { profile["weightKg"] = weightKg }
        if hasOverride(.heightCm) { profile["heightCm"] = heightCm }
        if waistCm > 0 { profile["waistCm"] = waistCm }
        if hasOverride(.stepTicksPerStep) { profile["stepTicksPerStep"] = stepTicksPerStep }
        let choices = algorithmChoices
        var config: [String: Any] = ["schemaVersion": 1, "effortMethod": choices.effortMethod,
            "deepHrvWindow": hrvWindowRaw == "deep", "useSleepStagerV2": choices.useSleepStagerV2,
            "useMotionAwareWake": choices.useMotionAwareWake,
            "daytimePersonalBaselineEnabled": choices.daytimePersonalBaselineEnabled,
            "spo2CandidateDisplayEnabled": choices.spo2CandidateDisplayEnabled,
            "journalContextEnabled": consent.journalEnabled, "cycleAwarenessEnabled": consent.cycleEnabled,
            "stepsManualCoefficient": stepsManualCoefficient, "hrvBaselineEpoch": hrvBaselineEpoch,
            "recoveryBaselineEpoch": recoveryBaselineEpoch]
        if hrMaxOverride > 0 || ageExplicit {
            config["maxHR"] = hrMaxOverride > 0 ? hrMaxOverride : Int((208 - 0.7 * Double(age)).rounded())
        }
        if hrZoneThresholds.count == 5 { config["customHRZoneLowerBounds"] = hrZoneThresholds }
        return (try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys]),
                try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]))
    }

    static func defaultsKey(_ key: ScoringPreferenceKey) -> String {
        switch key {
        case .effortMethod: return "noopBanisterEffort"
        case .useSleepStagerV2: return "noopExperimentalSleepV2"
        case .useMotionAwareWake: return "noopMotionAwareWake"
        case .daytimePersonalBaselineEnabled: return "noopStressPersonalBaseline"
        case .spo2CandidateDisplayEnabled: return "noopSpo2CandidateDisplay"
        case .hrvWindow: return "hrv.window"
        case .hrvBaselineEpoch: return "noop.hrvBaselineEpoch"
        case .recoveryBaselineEpoch: return "noop.recoveryBaselineEpoch"
        default: return "profile." + key.rawValue
        }
    }

    @MainActor func mirror(to defaults: UserDefaults, allowing: () -> Bool,
                           afterKey: ((ScoringPreferenceKey) -> Void)? = nil) {
        for key in ScoringPreferenceKey.allCases {
            guard allowing() else { return }
            // Undated legacy values are not promoted or rewritten during journal hydration.
            guard let value = values[key], provenance[key] != .accountLegacy else { continue }
            let target = Self.defaultsKey(key)
            switch value {
            case .clear: defaults.removeObject(forKey: target)
            case .number(let number):
                defaults.set(key == .dateOfBirth ? Date(timeIntervalSince1970: number) as Any : number as Any, forKey: target)
            case .boolean(let flag): defaults.set(flag, forKey: target)
            case .text(let text): defaults.set(key == .effortMethod ? (text == "BANISTER") as Any : text as Any, forKey: target)
            case .integers(let numbers):
                if numbers.isEmpty { defaults.removeObject(forKey: target) }
                else { defaults.set(numbers.map(String.init).joined(separator: ","), forKey: target) }
            }
            if key == .dateOfBirth {
                guard allowing() else { return }
                // Rebuild the existing backup-format age cache only. Frozen server bytes retain
                // age at the completed action, never this later presentation-mirror clock.
                if value == .clear { defaults.removeObject(forKey: "profile.age") }
                else { defaults.set(Calendar.current.dateComponents([.year], from: dateOfBirth, to: Date()).year ?? 0,
                                    forKey: "profile.age") }
            }
            afterKey?(key)
        }
    }
}

struct ScoringPreferenceCapture: Sendable {
    let context: AccountSessionContext
    let occurredAt: Date
    let timezone: String
    let sourceDeviceID: String?
    let disposition: ScoringPreferenceIntent.Disposition
    let consent: ScoringPreferenceSnapshot.Consent?
    let allowing: (@Sendable () -> Bool)?
}

struct ScoringPreferenceAction: Sendable {
    let patch: [ScoringPreferenceIntent.Patch]
    let capture: ScoringPreferenceCapture
}
