import Foundation
import NoopPush

/// A position in this account journal, independent of transport client revisions and consent origins.
struct ScoringPreferencePosition: Codable, Sendable, Equatable {
    let sequence: Int64
    let id: UUID?
    static let initial = Self(sequence: 0, id: nil)
    var isValid: Bool { sequence >= 0 && ((sequence == 0) == (id == nil)) }
}

enum ScoringPreferenceKey: String, Codable, CaseIterable, Sendable {
    case dateOfBirth, ageExplicit, sex, weightKg, heightCm, waistCm, hrMaxOverride
    case hrZoneThresholds, stepTicksPerStep, stepsManualCoefficient, hrvWindow
    case hrvBaselineEpoch, recoveryBaselineEpoch
    case effortMethod, useSleepStagerV2, useMotionAwareWake
    case daytimePersonalBaselineEnabled, spo2CandidateDisplayEnabled
}

enum ScoringPreferenceValue: Codable, Sendable, Equatable {
    case clear, boolean(Bool), number(Double), text(String), integers([Int])

    func validate(for key: ScoringPreferenceKey) throws {
        if self == .clear { return }
        let valid: Bool
        switch (key, self) {
        case (.ageExplicit, .boolean), (.useSleepStagerV2, .boolean), (.useMotionAwareWake, .boolean),
             (.daytimePersonalBaselineEnabled, .boolean), (.spo2CandidateDisplayEnabled, .boolean): valid = true
        case (.sex, .text(let value)): valid = ["male", "female", "nonbinary"].contains(value)
        case (.hrvWindow, .text(let value)): valid = ["whole", "deep"].contains(value)
        case (.effortMethod, .text(let value)): valid = ["BANISTER", "EDWARDS"].contains(value)
        case (.hrZoneThresholds, .integers(let values)):
            valid = values.isEmpty || (values.count == 5 && values.allSatisfy { (30...250).contains($0) }
                && zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        case (_, .number(let value)):
            switch key {
            case .dateOfBirth: valid = value.isFinite && (-2_208_988_800...7_289_654_400).contains(value)
            case .weightKg: valid = value.isFinite && (30...250).contains(value)
            case .heightCm: valid = value.isFinite && (120...230).contains(value)
            case .waistCm: valid = value.isFinite && (0...200).contains(value)
            case .hrMaxOverride: valid = value.isFinite && (0...230).contains(value) && value.rounded() == value
            case .stepTicksPerStep: valid = value.isFinite && (0.5...30).contains(value)
            case .stepsManualCoefficient: valid = value.isFinite && (0...1_000_000).contains(value)
            case .hrvBaselineEpoch, .recoveryBaselineEpoch: valid = value.isFinite && (0...7_289_654_400).contains(value)
            default: valid = false
            }
        default: valid = false
        }
        guard valid else { throw ScoringInputJournal.Failure.invalidInput }
    }
}

/// Construct from an explicit completed action. Recovery never samples preferences or a clock.
struct ScoringPreferenceIntent: Sendable, Equatable {
    enum Disposition: String, Codable, Sendable { case serverCoupled, localOnly }
    struct Patch: Codable, Sendable, Equatable {
        let key: ScoringPreferenceKey
        let value: ScoringPreferenceValue
    }
    private struct Envelope: Codable {
        let version: Int
        let project: String
        let user: String
        let generation: UUID
        let id: UUID
        let predecessor: ScoringPreferencePosition
        let occurredAt: Double
        let timezone: String
        let effectiveDay: String
        let device: String?
        let disposition: Disposition
        let patch: [Patch]
        let profile: Data?
        let config: Data?
        let profileMutationID: UUID?
        let configMutationID: UUID?
    }
    let context: AccountSessionContext
    let id: UUID
    let predecessor: ScoringPreferencePosition
    let occurredAt: Date
    let timezone: String
    let effectiveDay: String
    let device: String?
    let disposition: Disposition
    let patch: [Patch]
    let profile: ScoringInputChange?
    let config: ScoringInputChange?
    let profileMutationID: UUID?
    let configMutationID: UUID?
    var position: ScoringPreferencePosition { .init(sequence: predecessor.sequence + 1, id: id) }

    init(context: AccountSessionContext, id: UUID = UUID(), predecessor: ScoringPreferencePosition,
         occurredAt: Date, timezone: String, device: String?, disposition: Disposition,
         patch: [Patch], profilePayload: Data? = nil, configPayload: Data? = nil,
         profileMutationID: UUID? = nil, configMutationID: UUID? = nil) throws {
        guard predecessor.isValid, predecessor.sequence < Int64.max, predecessor.id != id,
              occurredAt.timeIntervalSince1970.isFinite, let zone = TimeZone(identifier: timezone),
              !patch.isEmpty, patch.count <= ScoringPreferenceKey.allCases.count,
              Set(patch.map(\.key)).count == patch.count else { throw ScoringInputJournal.Failure.invalidInput }
        let day = ServerScoreDate.day(occurredAt, timeZone: zone)
        guard ServerScoreDate.isDay(day), day >= "1900-01-01", day <= "2200-12-31" else {
            throw ScoringInputJournal.Failure.invalidInput
        }
        for item in patch { try item.value.validate(for: item.key) }
        let canonicalDevice: String?
        if let device {
            guard let uuid = UUID(uuidString: device) else { throw ScoringInputJournal.Failure.invalidInput }
            canonicalDevice = uuid.uuidString.lowercased()
        } else { canonicalDevice = nil }
        self.context = context; self.id = id; self.predecessor = predecessor
        self.occurredAt = occurredAt; self.timezone = timezone; self.effectiveDay = day
        self.device = canonicalDevice; self.disposition = disposition
        self.patch = patch.sorted { $0.key.rawValue < $1.key.rawValue }
        switch disposition {
        case .serverCoupled:
            guard let canonicalDevice, let profilePayload, let configPayload else { throw ScoringInputJournal.Failure.invalidInput }
            try Self.validatePayload(profilePayload, profile: true, timezone: timezone)
            try Self.validatePayload(configPayload, profile: false, timezone: timezone)
            profile = try .init(device: canonicalDevice, kind: .profile, entity: "primary", effectiveDay: day, payload: profilePayload)
            config = try .init(device: canonicalDevice, kind: .config, entity: "primary", effectiveDay: day, payload: configPayload)
            self.profileMutationID = profileMutationID ?? UUID()
            self.configMutationID = configMutationID ?? UUID()
            guard self.profileMutationID != self.configMutationID, self.profileMutationID != id, self.configMutationID != id else {
                throw ScoringInputJournal.Failure.invalidInput
            }
        case .localOnly:
            guard profilePayload == nil, configPayload == nil, profileMutationID == nil, configMutationID == nil else {
                throw ScoringInputJournal.Failure.invalidInput
            }
            profile = nil; config = nil; self.profileMutationID = nil; self.configMutationID = nil
        }
    }

    // This boundary accepts ordinary settings only, not notes, consent decisions or sensitive inputs.
    private static func validatePayload(_ data: Data, profile: Bool, timezone: String) throws {
        guard data.count <= 65536, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = value["schemaVersion"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(),
              schema.doubleValue == 1 else { throw ScoringInputJournal.Failure.invalidInput }
        let profileKeys: Set<String> = ["schemaVersion", "timezone", "age", "sex", "weightKg", "heightCm", "waistCm", "stepTicksPerStep"]
        let configKeys: Set<String> = ["schemaVersion", "maxHR", "effortMethod", "deepHrvWindow", "useSleepStagerV2", "useMotionAwareWake",
            "journalContextEnabled", "cycleAwarenessEnabled", "daytimePersonalBaselineEnabled", "spo2CandidateDisplayEnabled",
            "stepsManualCoefficient", "hrvBaselineEpoch", "recoveryBaselineEpoch", "customHRZoneLowerBounds"]
        guard Set(value.keys).isSubset(of: profile ? profileKeys : configKeys),
              !profile || value["timezone"] as? String == timezone else { throw ScoringInputJournal.Failure.invalidInput }
        func number(_ key: String, range: ClosedRange<Double>) throws {
            guard let raw = value[key], !(raw is NSNull) else { return }
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, range.contains(n.doubleValue) else { throw ScoringInputJournal.Failure.invalidInput }
        }
        if profile {
            for key in ["age", "weightKg", "heightCm", "waistCm", "stepTicksPerStep"] {
                try number(key, range: Double.leastNonzeroMagnitude...500)
            }
            if let sex = value["sex"], !(sex is NSNull) {
                guard let text = sex as? String, ["male", "female", "nonbinary"].contains(text) else { throw ScoringInputJournal.Failure.invalidInput }
            }
        } else {
            for key in ["deepHrvWindow", "useSleepStagerV2", "useMotionAwareWake", "journalContextEnabled", "cycleAwarenessEnabled",
                        "daytimePersonalBaselineEnabled", "spo2CandidateDisplayEnabled"] {
                if let raw = value[key] {
                    guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw ScoringInputJournal.Failure.invalidInput }
                }
            }
            try number("maxHR", range: 80...240)
            try number("stepsManualCoefficient", range: 0...1_000_000)
            try number("hrvBaselineEpoch", range: 0...Double.greatestFiniteMagnitude)
            try number("recoveryBaselineEpoch", range: 0...Double.greatestFiniteMagnitude)
            if let raw = value["effortMethod"] {
                guard let text = raw as? String, ["BANISTER", "EDWARDS"].contains(text) else { throw ScoringInputJournal.Failure.invalidInput }
            }
            if let raw = value["customHRZoneLowerBounds"], !(raw is NSNull) {
                guard let values = raw as? [NSNumber], values.count == 5,
                      values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && (30...250).contains($0.doubleValue) }),
                      zip(values, values.dropFirst()).allSatisfy({ $0.doubleValue < $1.doubleValue }) else { throw ScoringInputJournal.Failure.invalidInput }
            }
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Envelope(version: 1, project: context.scope.projectURL, user: context.scope.userID,
            generation: context.generation, id: id, predecessor: predecessor, occurredAt: occurredAt.timeIntervalSince1970,
            timezone: timezone, effectiveDay: effectiveDay, device: device, disposition: disposition, patch: patch,
            profile: profile?.payload, config: config?.payload, profileMutationID: profileMutationID, configMutationID: configMutationID))
    }

    init(encoded: Data) throws {
        guard encoded.count <= 192 * 1024 else { throw ScoringInputJournal.Failure.invalidInput }
        let value = try JSONDecoder().decode(Envelope.self, from: encoded)
        guard value.version == 1 else { throw ScoringInputJournal.Failure.invalidInput }
        try self.init(context: .init(scope: try AccountScope(projectURL: value.project, userID: value.user), generation: value.generation),
            id: value.id, predecessor: value.predecessor, occurredAt: Date(timeIntervalSince1970: value.occurredAt),
            timezone: value.timezone, device: value.device, disposition: value.disposition, patch: value.patch,
            profilePayload: value.profile, configPayload: value.config,
            profileMutationID: value.profileMutationID, configMutationID: value.configMutationID)
        guard effectiveDay == value.effectiveDay, try self.encoded() == encoded else { throw ScoringInputJournal.Failure.invalidInput }
    }
}

struct ScoringPreferenceAdmission: Sendable, Equatable {
    let position: ScoringPreferencePosition
    let profileMutationID: UUID?
    let configMutationID: UUID?
    let profileClientRevision: Int64?
    let configClientRevision: Int64?
}

struct ScoringPreferenceProjection: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let key: ScoringPreferenceKey
        let value: ScoringPreferenceValue
        let position: ScoringPreferencePosition
        let originGeneration: UUID
        let disposition: ScoringPreferenceIntent.Disposition
    }
    let scope: AccountScope
    let position: ScoringPreferencePosition
    let entries: [Entry]
}
