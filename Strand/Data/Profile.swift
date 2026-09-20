import Foundation
import Combine
import SwiftUI
import StrandAnalytics

/// User profile (age/sex/body metrics/HR-max) persisted in UserDefaults.
/// Powers HR zones, calories and recovery baselines.
@MainActor
final class ProfileStore: ObservableObject {
    /// Canonical source of truth for age (#146): a date of birth, so age advances on its own instead
    /// of silently going stale until the user remembers to bump a number. `age` is derived from this.
    @Published private var localDateOfBirth: Date {
        didSet {
            guard active else { return }
            d.set(dateOfBirth, forKey: K.dateOfBirth)
            d.set(true, forKey: "profile.ageExplicit")
            // Mirror the DERIVED age under the legacy `profile.age` key so the `.noopbak` backup
            // whitelist (which carries an Int age, not a Date) keeps exporting a correct value with no
            // change to the cross-platform backup contract. `BackupSettings.apply` clears
            // `profile.dateOfBirth` on restore so a restored Int age re-derives the DOB here.
            d.set(age, forKey: K.legacyAge)
        }
    }
    @Published private var localSex: String { didSet { if active { d.set(sex, forKey: K.sex) } } }
    @Published private var localWeightKg: Double { didSet { if active { d.set(weightKg, forKey: K.weight) } } }
    @Published private var localHeightCm: Double { didSet { if active { d.set(heightCm, forKey: K.height) } } }
    /// Optional waist circumference (cm); 0 = not set. Only used to ALSO show an estimated VO₂max
    /// alongside Fitness Age — the Fitness Age itself does not need it (the body term cancels).
    @Published private var localWaistCm: Double { didSet { if active { d.set(waistCm, forKey: K.waist) } } }
    /// 0 = auto-estimate from age.
    @Published private var localHrMaxOverride: Int { didSet { if active { d.set(hrMaxOverride, forKey: K.hrMax) } } }
    /// Five personalized inclusive zone starts in BPM; empty = conventional %HRmax zones.
    @Published private var localHrZoneThresholds: [Int] {
        didSet {
            guard active else { return }
            if hrZoneThresholds.isEmpty { d.removeObject(forKey: K.hrZoneThresholds) }
            else { d.set(hrZoneThresholds.map(String.init).joined(separator: ","), forKey: K.hrZoneThresholds) }
        }
    }
    /// Step-calibration divisor (#139/#132): counter ticks per real step for the @57 motion
    /// counter. 1.0 = raw pass-through (default — no behavior change). Clamped 0.5–30.0
    /// (WHOOP 5/MG motion-counter overcount can reach ~24×, so the ceiling has to be high).
    @Published private var localStepTicksPerStep: Double {
        didSet { if active { d.set(min(max(stepTicksPerStep, 0.5), 30.0), forKey: K.stepScale) } }
    }

    // ── Steps ESTIMATE calibration (WHOOP 4.0; StepsEstimateEngine) ─────────────────────────────
    // Written by IntelligenceEngine each analytics pass from the auto-fit against phone steps, and
    // read by the Settings/Steps screen to display + adjust the calibration. `stepsManualCoefficient`
    // is the ONLY user-settable field (0 = auto-fit; > 0 = manual override fed into calibrate()); the
    // other three are fitted outputs, surfaced read-only.
    /// Fitted (or manually-set) steps-per-unit-of-motion coefficient last persisted by the engine.
    @Published var stepsCalibrationCoefficient: Double { didSet { if active { d.set(stepsCalibrationCoefficient, forKey: K.stepsCoeff) } } }
    /// How many calibration days fed the last auto-fit (0 when purely manual / not yet fit).
    @Published var stepsCalibrationSampleDays: Int { didSet { if active { d.set(stepsCalibrationSampleDays, forKey: K.stepsSampleDays) } } }
    /// 0–1 trust in the last fit (1.0 for a manual coefficient).
    @Published var stepsCalibrationConfidence: Double { didSet { if active { d.set(stepsCalibrationConfidence, forKey: K.stepsConfidence) } } }
    /// True when the persisted coefficient came from the user's manual override, not an auto-fit.
    @Published var stepsCalibrationManual: Bool { didSet { if active { d.set(stepsCalibrationManual, forKey: K.stepsManualFlag) } } }
    /// User-set manual coefficient. 0 = auto-fit (nil to the engine); > 0 = manual override.
    @Published private var localStepsManualCoefficient: Double { didSet { if active { d.set(max(0, stepsManualCoefficient), forKey: K.stepsManualCoeff) } } }
    /// #1816: true when the strap has banked ANY motion (gravity samples → `dayMotionIntensity > 0`)
    /// in the calibration scan window. Written by `IntelligenceEngine` on every analytics pass so it
    /// tracks a fresh strap's first sync without a separate query. The Today tile reads this to decide
    /// whether "Need N more days where your phone also counted steps" is the honest caption or a lie:
    /// a step estimate is `motion * coefficient`, so with the motion half missing neither the estimate
    /// nor the fit moves however many phone-counted days the user collects. The caption that names only
    /// the phone half is actively misleading — it sent a field reporter to enter Apple Health steps by
    /// hand expecting calibration to start, which it cannot without strap motion. Twin of Android's
    /// `ProfileStore.stepsHasBankedMotion`.
    @Published var stepsHasBankedMotion: Bool { didSet { if active { d.set(stepsHasBankedMotion, forKey: K.stepsHasMotion) } } }

    // ── Profile picture (optional, on-device only) ──────────────────────────────────────────────
    /// The user's chosen profile photo as JPEG bytes, or nil for the default SF-Symbol fallback.
    /// LOCAL-ONLY — like every other field here it lives in UserDefaults on this device; NOOP is
    /// fully offline so this is never uploaded anywhere. Always set via ``setAvatar(_:)`` (which
    /// downscales) rather than written directly, so the persisted blob stays small (~256px).
    @Published var avatarImageData: Data? {
        didSet {
            guard active else { return }
            if let avatarImageData { d.set(avatarImageData, forKey: K.avatar) }
            else { d.removeObject(forKey: K.avatar) }
        }
    }

    private let d: UserDefaults
    private let domainName: String?
    private let defaultDOB: Date
    private var active = true
    private var scoringBound = false
    private weak var scoringPreferences: ScoringPreferenceRuntime?
    private var scoringSubscription: AnyCancellable?
    private var acceptedPreferences: ScoringPreferenceSnapshot? { active ? scoringPreferences?.accepted : nil }
    private func stored(_ key: String) -> Any? {
        if let domainName { return d.persistentDomain(forName: domainName)?[key] }
        return d.object(forKey: key)
    }
    func retire() { active = false; scoringSubscription = nil; scoringPreferences = nil }

    func bindScoringPreferences(_ runtime: ScoringPreferenceRuntime) {
        guard active, !scoringBound else { return }
        scoringBound = true; scoringPreferences = runtime
        scoringSubscription = runtime.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    // Legacy setters remain local. A bound account is changed only by a completed runtime action.
    var dateOfBirth: Date {
        get { scoringBound ? acceptedPreferences?.dateOfBirth ?? defaultDOB : localDateOfBirth }
        set { if active && !scoringBound { localDateOfBirth = newValue } }
    }
    var sex: String {
        get { scoringBound ? acceptedPreferences?.sex ?? "male" : localSex }
        set { if active && !scoringBound { localSex = newValue } }
    }
    var weightKg: Double {
        get { scoringBound ? acceptedPreferences?.weightKg ?? 75 : localWeightKg }
        set { if active && !scoringBound { localWeightKg = newValue } }
    }
    var heightCm: Double {
        get { scoringBound ? acceptedPreferences?.heightCm ?? 178 : localHeightCm }
        set { if active && !scoringBound { localHeightCm = newValue } }
    }
    var waistCm: Double {
        get { scoringBound ? acceptedPreferences?.waistCm ?? 0 : localWaistCm }
        set { if active && !scoringBound { localWaistCm = newValue } }
    }
    var hrMaxOverride: Int {
        get { scoringBound ? acceptedPreferences?.hrMaxOverride ?? 0 : localHrMaxOverride }
        set { if active && !scoringBound { localHrMaxOverride = newValue } }
    }
    var hrZoneThresholds: [Int] {
        get { scoringBound ? acceptedPreferences?.hrZoneThresholds ?? [] : localHrZoneThresholds }
        set { if active && !scoringBound { localHrZoneThresholds = newValue } }
    }
    var stepTicksPerStep: Double {
        get { scoringBound ? acceptedPreferences?.stepTicksPerStep ?? 1 : localStepTicksPerStep }
        set { if active && !scoringBound { localStepTicksPerStep = newValue } }
    }
    var stepsManualCoefficient: Double {
        get { scoringBound ? acceptedPreferences?.stepsManualCoefficient ?? 0 : localStepsManualCoefficient }
        set { if active && !scoringBound { localStepsManualCoefficient = newValue } }
    }

    /// Do not turn the setup screen's defaults into measured/confirmed server profile inputs.
    var scoringProfileValues: [String: Any] {
        var value: [String: Any] = [:]
        if scoringBound {
            guard let snapshot = acceptedPreferences else { return value }
            if snapshot.ageExplicit { value["age"] = age }
            if snapshot.hasOverride(.sex) { value["sex"] = sex }
            if snapshot.hasOverride(.weightKg) { value["weightKg"] = weightKg }
            if snapshot.hasOverride(.heightCm) { value["heightCm"] = heightCm }
            if waistCm > 0 { value["waistCm"] = waistCm }
            if snapshot.hasOverride(.stepTicksPerStep) { value["stepTicksPerStep"] = stepTicksPerStep }
            return value
        }
        if stored("profile.ageExplicit") as? Bool == true { value["age"] = age }
        if stored(K.sex) != nil { value["sex"] = sex }
        if stored(K.weight) != nil { value["weightKg"] = weightKg }
        if stored(K.height) != nil { value["heightCm"] = heightCm }
        if waistCm > 0 { value["waistCm"] = waistCm }
        if stored(K.stepScale) != nil { value["stepTicksPerStep"] = stepTicksPerStep }
        return value
    }

    var confirmedMaxHR: Int? {
        hrMaxOverride > 0 || (scoringBound ? acceptedPreferences?.ageExplicit == true : stored("profile.ageExplicit") as? Bool == true) ? hrMax : nil
    }
    private enum K {
        static let dateOfBirth = "profile.dateOfBirth"
        /// Pre-#146 age key. No longer the source of truth; kept mirrored from `dateOfBirth` so the
        /// cross-platform `.noopbak` whitelist keeps round-tripping an Int age unchanged.
        static let legacyAge = "profile.age"
        static let sex = "profile.sex", weight = "profile.weightKg"
        static let height = "profile.heightCm", hrMax = "profile.hrMaxOverride"
        static let hrZoneThresholds = "profile.hrZoneThresholds"
        static let stepScale = "profile.stepTicksPerStep"
        static let waist = "profile.waistCm"
        static let stepsCoeff = "profile.stepsCalibrationCoefficient"
        static let stepsSampleDays = "profile.stepsCalibrationSampleDays"
        static let stepsConfidence = "profile.stepsCalibrationConfidence"
        static let stepsManualFlag = "profile.stepsCalibrationManual"
        static let stepsManualCoeff = "profile.stepsManualCoefficient"
        static let stepsHasMotion = "profile.stepsHasBankedMotion"
        static let avatar = "profile.avatarImageData"
    }

    init(defaults: UserDefaults = .standard, domainName: String? = nil) {
        self.d = defaults
        self.domainName = domainName
        self.defaultDOB = Self.dateOfBirth(forAge: 30)
        let domain = domainName.map { defaults.persistentDomain(forName: $0) ?? [:] }
        func stored(_ key: String) -> Any? { if let domain { return domain[key] }; return defaults.object(forKey: key) }
        // #146 age migration. `dateOfBirth` is authoritative whenever it exists, so age advances on
        // its own. A pre-#146 install — or a `.noopbak` restore, which writes only the legacy Int age
        // and clears any stale DOB (see `BackupSettings.apply`) — has no DOB yet, so derive one from
        // the stored age. Nothing stored → the age-30 default. Deliberately NO equality heuristic: a
        // present DOB is never second-guessed against the mirrored age (doing so would re-freeze age
        // every birthday, the exact staleness #146 fixes).
        let resolvedDOB: Date
        if let dob = stored(K.dateOfBirth) as? Date {
            resolvedDOB = dob
        } else if let legacyAge = stored(K.legacyAge) as? Int {
            resolvedDOB = Self.dateOfBirth(forAge: legacyAge)
        } else {
            resolvedDOB = Self.dateOfBirth(forAge: 30)
        }
        localDateOfBirth = resolvedDOB
        // `didSet` doesn't fire for the initial assignment inside `init`, so persist the resolved DOB
        // and its mirrored age explicitly — otherwise a migrated/derived DOB never reaches storage
        // until the user next edits it. Written from the LOCAL (not `self.dateOfBirth`, which Swift
        // forbids reading before every stored property is initialized).
        if domainName == nil {
            d.set(resolvedDOB, forKey: K.dateOfBirth)
            d.set(Self.years(from: resolvedDOB, to: Date()), forKey: K.legacyAge)
        }
        localSex = stored(K.sex) as? String ?? "male"
        localWeightKg = stored(K.weight) as? Double ?? 75
        localHeightCm = stored(K.height) as? Double ?? 178
        localWaistCm = stored(K.waist) as? Double ?? 0
        localHrMaxOverride = stored(K.hrMax) as? Int ?? 0
        let storedThresholds = (stored(K.hrZoneThresholds) as? String)?
            .split(separator: ",").compactMap { Int($0) } ?? []
        localHrZoneThresholds = Self.validZoneThresholds(storedThresholds) ? storedThresholds : []
        localStepTicksPerStep = min(max(stored(K.stepScale) as? Double ?? 1.0, 0.5), 30.0)
        stepsCalibrationCoefficient = stored(K.stepsCoeff) as? Double ?? 0
        stepsCalibrationSampleDays = stored(K.stepsSampleDays) as? Int ?? 0
        stepsCalibrationConfidence = stored(K.stepsConfidence) as? Double ?? 0
        stepsCalibrationManual = stored(K.stepsManualFlag) as? Bool ?? false
        localStepsManualCoefficient = max(0, stored(K.stepsManualCoeff) as? Double ?? 0)
        stepsHasBankedMotion = stored(K.stepsHasMotion) as? Bool ?? false
        avatarImageData = stored(K.avatar) as? Data
    }

    // MARK: - Profile picture

    /// The profile photo as a SwiftUI `Image`, or nil when none is set (callers fall back to the
    /// `person.crop.circle` SF Symbol). Bridges the stored JPEG bytes through the platform bitmap
    /// type (`NSImage`/`UIImage`) via the shared `Image(platformImage:)` initializer.
    var avatarImage: Image? {
        guard let data = avatarImageData, let img = PlatformImage(data: data) else { return nil }
        return Image(platformImage: img)
    }

    /// Whether a profile photo is set.
    var hasAvatar: Bool { avatarImageData != nil }

    /// Set the profile photo from raw image bytes (e.g. from a `PhotosPicker` / `NSOpenPanel`),
    /// downscaling to a small square so the persisted UserDefaults blob stays tiny. Passing nil
    /// clears it. If downscaling can't decode the bytes, the originals are stored as-is rather than
    /// dropping the user's pick. To remove a photo, pass nil or call ``clearAvatar()``.
    func setAvatar(_ data: Data?) {
        guard let data else { avatarImageData = nil; return }
        // Downscale to ~256px before persisting; fall back to the raw bytes if decoding fails so a
        // valid-but-unusual image still saves rather than silently dropping.
        avatarImageData = AvatarImage.downscaledJPEG(from: data, maxDimension: 256) ?? data
    }

    /// Remove the profile photo (reverts the header / Settings to the default icon).
    func clearAvatar() { avatarImageData = nil }

    /// The manual override to feed into `StepsEstimateEngine.calibrate(_:manualOverride:)`:
    /// nil when 0 (auto-fit), the positive value otherwise.
    var stepsManualOverride: Double? { stepsManualCoefficient > 0 ? stepsManualCoefficient : nil }

    /// Current age in whole years, derived from `dateOfBirth` (#146) rather than a number the user has
    /// to remember to update. Every existing caller (HR zones, calories, Fitness/Body Age) reads this
    /// unchanged.
    var age: Int { Self.years(from: dateOfBirth, to: Date()) }

    /// Whole years elapsed `from`→`to` (floor — a birthday not yet reached this year doesn't count).
    nonisolated static func years(from: Date, to: Date) -> Int {
        Calendar.current.dateComponents([.year], from: from, to: to).year ?? 0
    }

    /// A date of birth `age` whole years before today, anchored to today's month/day so the derived
    /// age is exactly `age`. Used to migrate a stored manual age and to seed the DOB picker.
    nonisolated static func dateOfBirth(forAge age: Int) -> Date {
        Calendar.current.date(byAdding: .year, value: -age, to: Date()) ?? Date()
    }

    /// Bounds for the DOB picker, matching the old 13...100 age `Stepper` range so a pick can't derive
    /// an out-of-range age.
    nonisolated static var dateOfBirthRange: ClosedRange<Date> {
        dateOfBirth(forAge: 100)...dateOfBirth(forAge: 13)
    }

    /// Tanaka estimate unless overridden.
    var hrMax: Int { hrMaxOverride > 0 ? hrMaxOverride : Int((208 - 0.7 * Double(age)).rounded()) }

    /// Personalized zone starts after enforcing the same five-value invariant as `HRZones`.
    var customHRZoneLowerBounds: [Double]? {
        guard Self.validZoneThresholds(hrZoneThresholds) else { return nil }
        return hrZoneThresholds.map(Double.init)
    }

    /// The single display-zone model used by live HR, workout splits, and haptic coaching.
    var hrZoneSet: HRZoneSet {
        HRZones.zones(maxHR: Double(hrMax), customLowerBounds: customHRZoneLowerBounds)
    }

    var hasCustomHRZones: Bool { customHRZoneLowerBounds != nil }

    /// Enable by seeding the editor with boundaries that classify integer BPM exactly like today's
    /// conventional percentages; disabling removes the override and immediately restores defaults.
    func setCustomHRZonesEnabled(_ enabled: Bool) {
        hrZoneThresholds = enabled ? HRZones.defaultLowerBounds(maxHR: Double(hrMax)) : []
    }

    /// Move one boundary while preserving strict ordering. Neighbour-aware clamps make it impossible
    /// for the stepper to create a gap, overlap, or invalid persisted state.
    func stepHRZoneThreshold(at index: Int, up: Bool) {
        guard hrZoneThresholds.indices.contains(index) else { return }
        var next = hrZoneThresholds
        let floor = index == 0 ? HRZones.customBPMRange.lowerBound : next[index - 1] + 1
        let ceiling = index == next.count - 1 ? HRZones.customBPMRange.upperBound : next[index + 1] - 1
        guard floor <= ceiling else { return }   // no room between neighbours -> no-op (parity w/ Kotlin)
        next[index] = min(max(next[index] + (up ? 1 : -1), floor), ceiling)
        hrZoneThresholds = next
    }

    nonisolated static func validZoneThresholds(_ values: [Int]) -> Bool {
        guard values.count == 5,
              values.allSatisfy(HRZones.customBPMRange.contains) else { return false }
        return zip(values, values.dropFirst()).allSatisfy(<)
    }

    /// Whether the cycle-awareness opt-in applies to this profile (#801). Cycle phase is read from the
    /// MENSTRUAL skin-temperature shift, so the opt-in (the Health card + the Automations toggle) is only
    /// offered to profiles it can apply to and is NOT shown for male profiles. `sex` is the free String
    /// "male" | "female" | "nonbinary"; we gate by excluding "male" (case-insensitive) so any non-male
    /// value, including unrecognised ones, still sees the opt-in rather than being silently excluded.
    var cycleAwarenessApplies: Bool { Self.cycleAwarenessApplies(sex: sex) }

    /// Pure form of ``cycleAwarenessApplies`` for the given `sex` token, so the gate can be unit-tested
    /// without a live store / UserDefaults. `nonisolated` because it is a pure function over its argument
    /// (no actor state), so the gate and its tests can call it from any context.
    nonisolated static func cycleAwarenessApplies(sex: String) -> Bool {
        sex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "male"
    }

    /// Whether the cycle-awareness OFFER should be VISIBLE for a profile: eligible by sex AND not hidden
    /// by the user's "not for me" opt-out. `hidden` is USER-controlled and never age-derived — a
    /// respectful hide, not an assumption about menopause. Pure, so the combined gate is unit-testable.
    nonisolated static func cycleAwarenessVisible(sex: String, hidden: Bool) -> Bool {
        cycleAwarenessApplies(sex: sex) && !hidden
    }

    /// Allowed range for the step-calibration divisor (#132). 5/MG straps overcount by
    /// up to ~24×, so the old 4.0 ceiling could never reach the truth.
    static let stepScaleRange: ClosedRange<Double> = 0.5...30.0

    /// Variable step for the calibration stepper so high values stay reachable: fine near
    /// the 1.0 default (where most people land), coarse up at the 20s+ a 5/MG needs. A flat
    /// 0.1 step from 0.5 to 30 would be ~295 taps — unusable.
    /// - `< 2.0` → 0.1   (precision around the default)
    /// - `2.0–5.0` → 0.5
    /// - `≥ 5.0` → 1.0   (ballpark the ~24× overcount in ~19 taps)
    static func stepScaleIncrement(for value: Double) -> Double {
        switch value {
        case ..<2.0: return 0.1
        case ..<5.0: return 0.5
        default: return 1.0
        }
    }

    /// One increment/decrement of the calibration divisor, snapped to the increment grid and
    /// clamped to ``stepScaleRange``. Decrement uses the increment for the *target* band so the
    /// up/down sequence is symmetric at the band boundaries (e.g. 5.0 −1 → 4.0, 4.0 +0.5 → 4.5).
    static func steppedStepScale(_ value: Double, up: Bool) -> Double {
        let delta = up ? stepScaleIncrement(for: value)
                       : stepScaleIncrement(for: value - 0.0001)
        let next = ((value + (up ? delta : -delta)) / delta).rounded() * delta
        return min(max(next, stepScaleRange.lowerBound), stepScaleRange.upperBound)
    }
}
