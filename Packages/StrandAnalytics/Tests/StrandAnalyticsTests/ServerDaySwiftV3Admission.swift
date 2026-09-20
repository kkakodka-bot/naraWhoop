import Foundation
import WhoopProtocol
@testable import StrandAnalytics

enum ServerDaySwiftV3Admission {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    typealias H = ServerDaySwiftHistory
    typealias S = ServerDaySwiftV3Selection
    typealias T = ServerDaySwiftV3Thermal
    typealias Sleep = ServerDaySwiftV3Sleep

    enum ContextFlag: String, CaseIterable, Encodable {
        case alcohol, stress, sauna, hardOrLateWorkout, travelPhaseJump, alreadyUnwell
    }
    enum Answer: Equatable, Encodable {
        case unknown, no, yes
        var value: Bool? { self == .unknown ? nil : self == .yes }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            if let value { try c.encode(value) } else { try c.encodeNil() }
        }
    }
    enum ConsentPurpose: String, Encodable { case journal = "journal_context", cycle = "cycle_context" }
    struct ConsentEvidence: Encodable, Equatable {
        let purpose: ConsentPurpose
        let policyVersion: Int
        let decisionId: String
    }
    struct JournalIdentity: Encodable, Equatable {
        let userId: UUID
        let sourceDeviceId: UUID
        let kind: C.Kind
        let entity: String
        let revision: Int64
        let effectiveDay: String
        let deleted: Bool
        init(_ row: C.JournalRow) {
            userId = row.userId; sourceDeviceId = row.sourceDeviceId; kind = row.kind; entity = row.entity
            revision = row.revision; effectiveDay = row.effectiveDay; deleted = row.deleted
        }
    }
    struct ContextAnswers: Encodable, Equatable {
        let day: String
        let timezone: String
        let flags: [String: Answer]
        let consent: ConsentEvidence
        let identity: JournalIdentity
        var complete: Bool { ContextFlag.allCases.allSatisfy { flags[$0.rawValue]?.value != nil } }
    }
    struct PeriodStart: Encodable, Equatable {
        let day: String
        let timezone: String
        let consent: ConsentEvidence
        let identity: JournalIdentity
    }
    struct Decision: Encodable, Equatable {
        let inputDigest: String
        let policy: C.Policy
        let journalEnabled: Bool
        let cycleEnabled: Bool
        let daytimePersonalBaselineEnabled: Bool
        let answers: ContextAnswers?
        let periods: [PeriodStart]
        let selected: [C.JournalRow]
        let ignored: [JournalIdentity]
        let tombstoned: [JournalIdentity]
        let reasons: [String]
    }
    enum BaselineMetric: String, CaseIterable, Encodable {
        case hrv, readinessHrvLn = "readiness_hrv_ln", restingHR = "resting_hr", resp
        case skinTemp = "skin_temp", strain, daytimeHR = "daytime_hr", daytimeRMSSD = "daytime_rmssd"
    }
    struct MetricAdmission: Encodable, Equatable {
        let day: String
        let key: BaselineMetric
        let epoch: Double
        let utcDayStart: Int
        let beforeStatus: String?
        let admitted: Bool
        let reasons: [String]
    }

    static func failure(_ reason: String) -> C.Failure { .invalid("s13:" + reason) }
    static func date(_ value: C.JSON?) throws -> String {
        let day = try V.string(value)
        guard day.count == 10, day >= "1900-01-01", day <= "2200-12-31" else { throw failure("context_date") }
        _ = try C.dayBounds(day, "UTC")
        return day
    }
    static func consent(_ value: C.JSON?, purpose: ConsentPurpose) throws -> ConsentEvidence {
        guard let value else { throw failure("consent_missing") }
        let p = try V.object(value)
        try V.keys(p, required: "purpose policyVersion decisionId")
        let id = try V.string(p["decisionId"])
        guard p["purpose"] == .string(purpose.rawValue), p["policyVersion"] == .number(1),
              let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { throw failure("consent") }
        return ConsentEvidence(purpose: purpose, policyVersion: 1, decisionId: id)
    }
    static func entity(_ row: C.JournalRow) throws {
        if row.kind == .context {
            guard row.entity == "context:" + row.effectiveDay else { throw failure("context_entity") }
            _ = try date(.string(row.effectiveDay))
        } else if row.kind == .period {
            guard row.entity.hasPrefix("period:"), let id = UUID(uuidString: String(row.entity.dropFirst(7))),
                  row.entity == "period:" + id.uuidString.lowercased() else { throw failure("period_entity") }
        }
    }
    static func payload(_ row: C.JournalRow) throws -> (String, String) {
        try entity(row)
        let p = row.payload
        try V.keys(p, required: row.kind == .context ? "schemaVersion day timezone flags consent" : "schemaVersion day timezone event consent")
        let day = try date(p["day"]), zone = try V.string(p["timezone"])
        guard p["schemaVersion"] == .number(1), day == row.effectiveDay,
              TimeZone(identifier: zone) != nil else { throw failure("context_payload") }
        return (day, zone)
    }
    static func context(_ row: C.JournalRow) throws -> ContextAnswers {
        let (day, zone) = try payload(row)
        let flags = try V.object(row.payload["flags"]!)
        try V.keys(flags, required: ContextFlag.allCases.map(\.rawValue).joined(separator: " "))
        let answers: [String: Answer] = try flags.mapValues {
            switch $0 {
            case .null: return .unknown
            case .bool(let value): return value ? .yes : .no
            default: throw failure("context_flag")
            }
        }
        return ContextAnswers(day: day, timezone: zone, flags: answers,
            consent: try consent(row.payload["consent"], purpose: .journal), identity: JournalIdentity(row))
    }
    static func period(_ row: C.JournalRow) throws -> PeriodStart {
        let (day, zone) = try payload(row)
        guard row.payload["event"] == .string("period_start") else { throw failure("period_event") }
        return PeriodStart(day: day, timezone: zone, consent: try consent(row.payload["consent"], purpose: .cycle), identity: JournalIdentity(row))
    }

    static func resolve(_ input: V.Input) throws -> Decision {
        _ = try V.validate(input)
        let resolution = try C.resolve(input.historyInput), config = resolution.payload(.config)
        guard resolution.rows.allSatisfy({ [.profile, .config, .sleepEdit, .context, .period].contains($0.kind) || $0.deleted }),
              ["customHRZoneLowerBounds", "stepsManualCoefficient"].allSatisfy({ config[$0] == nil || config[$0] == .null }),
              config["spo2CandidateDisplayEnabled"] != .bool(true) else { throw failure("outside_context_scope") }
        let family = input.source.registryFamily?.lowercased()
        guard family.map({ S.modernFamilies.contains($0) || S.legacyFamilies.contains($0) }) == true,
              DeviceFamily.confirmedRegistryFamily(model: input.source.storeModel, brand: input.source.storeBrand) != nil else {
            throw failure("unknown_family_composition")
        }
        var periodDays: [String: String] = [:]
        for row in input.journal where row.userId == input.identity.userId && row.sourceDeviceId == input.identity.sourceDeviceId
            && row.effectiveDay <= input.day && [.context, .period].contains(row.kind) {
            try entity(row)
            if row.deleted { continue }
            if row.kind == .context { _ = try context(row) }
            else {
                let event = try period(row)
                if let day = periodDays[row.entity], day != event.day { throw failure("period_anchor_changed") }
                periodDays[row.entity] = event.day
            }
        }
        let contextRow = resolution.rows.first { $0.kind == .context && !$0.deleted && $0.entity == "context:" + input.day }
        let answers = try contextRow.map(context)
        let periods = try resolution.rows.filter { $0.kind == .period && !$0.deleted }.map(period)
            .sorted { ($0.day, $0.identity.entity) < ($1.day, $1.identity.entity) }
        let journal = config["journalContextEnabled"] == .bool(true), cycle = config["cycleAwarenessEnabled"] == .bool(true)
        var reasons: [String] = []
        if !journal { reasons.append("journal_context_not_shared") }
        else if answers?.complete != true { reasons.append("journal_context_incomplete") }
        if !cycle { reasons.append("cycle_context_not_shared") }
        else if periods.isEmpty { reasons.append("period_history_unavailable") }
        return Decision(inputDigest: try C.digest(input), policy: try C.policy(resolution, identity: input.identity),
            journalEnabled: journal, cycleEnabled: cycle, daytimePersonalBaselineEnabled: config["daytimePersonalBaselineEnabled"] == .bool(true),
            answers: answers, periods: periods, selected: resolution.rows,
            ignored: input.journal.filter { !resolution.rows.contains($0) }.map(JournalIdentity.init),
            tombstoned: resolution.rows.filter(\.deleted).map(JournalIdentity.init), reasons: reasons)
    }

    static func eligible(day: String, metric: BaselineMetric, policy: C.Policy,
                         before: [String: H.State], requireUsable: Bool = true) throws -> MetricAdmission {
        let epoch = policy.epoch(metric.rawValue), start = try C.dayBounds(day, "UTC").lowerBound
        var reasons: [String] = []
        if !epoch.isFinite || epoch < 0 || epoch > C.safeInteger { throw failure("reset_epoch") }
        if Double(start) < epoch { reasons.append("before_reset_epoch") }
        let state = try before[metric.rawValue]?.native()
        if requireUsable, state?.usable != true { reasons.append(state?.status == .stale ? "baseline_stale" : "baseline_learning") }
        return MetricAdmission(day: day, key: metric, epoch: epoch, utcDayStart: start,
            beforeStatus: state?.status.rawValue, admitted: reasons.isEmpty, reasons: reasons)
    }

    static func resolveSleep(input: V.Input, prepared: H.Prepared, loaded: S.Loaded,
                             thermal: T.Anchor, decision: Decision) throws -> Sleep.ResolvedSleep {
        let bounds = try V.validate(input)
        guard decision == (try resolve(input)), prepared.input == input.historyInput,
              loaded.evidence.bounds == bounds, loaded.evidence.effectiveConfig == prepared.resolution.payload(.config),
              thermal.family == DeviceFamily.confirmedRegistryFamily(model: input.source.storeModel, brand: input.source.storeBrand)?.rawValue else {
            throw failure("sleep_context")
        }
        let edits = try Sleep.edits(input, resolution: prepared.resolution)
        let automatic = try T.analyze(input, prepared: prepared, loaded: loaded, anchor: thermal)
        let resolved = Sleep.apply(edits, detected: automatic.sleepSessions, input: input, loaded: loaded)
        return Sleep.ResolvedSleep(input: input, selection: loaded.evidence, thermal: thermal,
            preparedDigest: try Sleep.contextDigest(prepared), automatic: automatic.sleepSessions.map(T.Session.init),
            authoritative: !edits.isEmpty, entries: resolved.entries, gaps: resolved.gaps)
    }

    static func prepareThermal(_ prepared: H.Prepared, history: [ServerDaySwiftV3Context.Observation],
                               anchor: T.Anchor) throws -> (H.Prepared, T.Evidence) {
        guard anchor.family == DeviceFamily.whoop4.rawValue else {
            return (prepared, T.Evidence(anchor: anchor, priorNights: [], beforeState: prepared.baselinesBefore["skin_temp"]!))
        }
        let eligible = history.filter { $0.checkpoint.policy.sourceEra == prepared.policy.sourceEra }
        var byDay: [String: T.RebasedNight] = [:]
        for observation in eligible {
            guard observation.input.identity == prepared.input.identity, observation.input.day < prepared.input.day,
                  DeviceFamily.confirmedRegistryFamily(model: observation.input.source.storeModel, brand: observation.input.source.storeBrand) == .whoop4,
                  byDay[observation.input.day] == nil else { throw failure("thermal_history") }
            let funnel = T.funnel(observation.rawNight, family: .whoop4, anchor: anchor.resolvedRaw)
            byDay[observation.input.day] = T.RebasedNight(caseID: observation.input.id, day: observation.input.day,
                inputDigest: observation.inputDigest, originalMean: observation.checkpoint.observation.measurements.values["skin_temp"],
                mean: funnel.mean, funnel: try ServerDaySwiftV3CoreProbe.reflect(funnel))
        }
        var state: BaselineState?
        let cfg = Baselines.metricCfg["skin_temp"]!
        for day in try C.days(from: eligible.first?.input.day ?? prepared.input.day, through: prepared.input.day).dropLast() {
            guard Double(try C.dayBounds(day, "UTC").lowerBound) >= prepared.policy.recoveryEpoch else { continue }
            state = Baselines.update(state, value: byDay[day]?.mean, cfg: cfg)
        }
        let thermal = H.State(state ?? Baselines.foldHistory([], cfg: cfg))
        var before = prepared.baselinesBefore; before["skin_temp"] = thermal
        let rebased = H.Prepared(input: prepared.input, resolution: prepared.resolution, policy: prepared.policy,
            history: prepared.history, eligibleHistory: prepared.eligibleHistory, baselinesBefore: before,
            needHours: prepared.needHours, consistency: prepared.consistency, habitualMidsleepSec: prepared.habitualMidsleepSec,
            reusedCheckpoint: prepared.reusedCheckpoint)
        return (rebased, T.Evidence(anchor: anchor, priorNights: eligible.compactMap { byDay[$0.input.day] }, beforeState: thermal))
    }
}
