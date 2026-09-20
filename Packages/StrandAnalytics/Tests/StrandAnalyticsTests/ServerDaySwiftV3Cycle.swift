import Foundation
import GRDB
import WhoopProtocol
@testable import StrandAnalytics

/// S12 additive evidence only. Workouts, presentation and a full snapshot are not composed here.
enum ServerDaySwiftV3Cycle {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    typealias H = ServerDaySwiftHistory
    typealias S = ServerDaySwiftV3Selection
    typealias Sleep = ServerDaySwiftV3Sleep
    typealias P = ServerDaySwiftV3CoreProbe

    struct Window: Codable, Equatable {
        let id: String
        let startInclusive: Int
        let endExclusive: Int
        let displayDay: String
        let source: String
        init(_ native: DayCycleWindow) {
            id = native.id; startInclusive = native.startInclusive; endExclusive = native.endExclusive; displayDay = native.displayDay
            switch native.source {
            case .calendar: source = "calendar"
            case .detectedSleep: source = "detected_sleep"
            case .editedSleep: source = "edited_sleep"
            case .syntheticMidnight: source = "synthetic_midnight"
            }
        }
        var native: DayCycleWindow {
            let kind: DayCycleWindow.Source = source == "calendar" ? .calendar : source == "edited_sleep" ? .editedSleep
                : source == "synthetic_midnight" ? .syntheticMidnight : .detectedSleep
            return DayCycleWindow(id: id, startInclusive: startInclusive, endExclusive: endExclusive, displayDay: displayDay, source: kind)
        }
    }

    /// Only obtained from this adapter's own execution, not a decoded/imported expected checkpoint.
    struct PriorResolvedSleep {
        fileprivate let input: V.Input
        fileprivate let sourceEra: String
        fileprivate let window: Window
        fileprivate let inputDigest: String
        fileprivate init(_ evidence: CycleEvidence) {
            input = evidence.input; sourceEra = evidence.sourceEra; window = evidence.window; inputDigest = evidence.inputDigest
        }
    }
    struct Energy: Codable, Equatable {
        let restingKcal: Double
        let activeKcal: Double
        let totalKcal: Double
        let observedSeconds: Double
        init(_ native: Calories.DayEnergyEstimate) {
            restingKcal = native.restingKcal; activeKcal = native.activeKcal; totalKcal = native.totalKcal; observedSeconds = native.observedSeconds
        }
    }
    /// Diagnostic output only. Only evaluate constructs this immutable result, so exported or
    /// decoded report fields cannot manufacture an own-execution prior. The input digest is a
    /// consistency check, not authentication of caller-supplied output or physiological execution.
    struct CycleEvidence: Encodable, Equatable {
        let input: V.Input
        let inputDigest: String
        let sourceEra: String
        let mode: String
        let window: Window
        let openAtCutoff: Bool
        let appliesToDay: Bool
        let classification: C.JSON
        let boundaryWindows: C.JSON
        let selected: [String: [V.StoredIdentity]]
        let predecessor: V.StoredIdentity?
        let rejectedStepIDs: [String]
        let retainedByOwner: [String: [String: Int]]
        let nativeDayResult: C.JSON
        let counter: C.JSON?
        let steps: Int?
        let strain: Double?
        let energy: Energy?
        let activeKcalEst: Double?
        let gaps: [String]
        var prior: PriorResolvedSleep { PriorResolvedSleep(self) }

        fileprivate init(input: V.Input, inputDigest: String, sourceEra: String, mode: String,
                         window: Window, openAtCutoff: Bool, appliesToDay: Bool, classification: C.JSON,
                         boundaryWindows: C.JSON, selected: [String: [V.StoredIdentity]],
                         predecessor: V.StoredIdentity?, rejectedStepIDs: [String],
                         retainedByOwner: [String: [String: Int]], nativeDayResult: C.JSON,
                         counter: C.JSON?, steps: Int?, strain: Double?, energy: Energy?,
                         activeKcalEst: Double?, gaps: [String]) {
            self.input = input; self.inputDigest = inputDigest; self.sourceEra = sourceEra; self.mode = mode
            self.window = window; self.openAtCutoff = openAtCutoff; self.appliesToDay = appliesToDay
            self.classification = classification; self.boundaryWindows = boundaryWindows; self.selected = selected
            self.predecessor = predecessor; self.rejectedStepIDs = rejectedStepIDs; self.retainedByOwner = retainedByOwner
            self.nativeDayResult = nativeDayResult; self.counter = counter; self.steps = steps; self.strain = strain
            self.energy = energy; self.activeKcalEst = activeKcalEst; self.gaps = gaps
        }
    }
    struct Loaded {
        let selected: [String: [V.StoredIdentity]]
        let predecessor: V.StoredIdentity?
        let rejectedStepIDs: [String]
        let hr: [HRSample]
        let gravity: [GravitySample]
        let steps: [StepSample]
        let gaps: [String]
    }

    static func calendar(_ input: V.Input) throws -> DayCycleWindow {
        let range = try DayCycleResolver.localDayBounds(day: input.day, timezone: TimeZone(identifier: input.timezone)!)
        guard range.upperBound == input.asOfExclusive else { throw V.failure("s12_cycle_cutoff") }
        return DayCycleWindow(id: "calendar:\(input.day)", startInclusive: range.lowerBound, endExclusive: range.upperBound,
            displayDay: input.day, source: .calendar)
    }

    static func load(_ seed: S.Seed, window: DayCycleWindow) async throws -> Loaded {
        guard window.startInclusive >= 0, window.endExclusive == seed.input.asOfExclusive,
              window.startInclusive < window.endExclusive else { throw V.failure("s12_cycle_query_window") }
        let device = seed.input.identity.sourceDeviceId.uuidString.lowercased()
        var rows: [C.Stream: [Row]] = [:]
        for stream in [C.Stream.hr, .gravity, .steps] {
            let table = S.tables[stream]!
            rows[stream] = try await seed.store.registryWriter.read { db in
                try Row.fetchAll(db, sql: "SELECT rowid AS fixtureRowId,* FROM \(table) WHERE deviceId=? AND ts>=? AND ts<? ORDER BY ts",
                    arguments: [device, window.startInclusive, window.endExclusive])
            }
        }
        let predecessor = try await seed.store.registryWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT rowid AS fixtureRowId,* FROM stepSample WHERE deviceId=? AND ts<? ORDER BY ts DESC LIMIT 1",
                arguments: [device, window.startInclusive])
        }
        func identity(_ row: Row, stream: C.Stream) throws -> V.StoredIdentity {
            let rowid: Int64 = row["fixtureRowId"]
            guard let original = seed.rows[rowid], original.userId == seed.input.identity.userId,
                  original.sourceDeviceId == seed.input.identity.sourceDeviceId, original.stream == stream,
                  original.ts == row["ts"] as Int else { throw V.failure("s12_cycle_row_identity") }
            return V.StoredIdentity(id: original.id, rowid: rowid, ts: original.ts, fields: original.fields)
        }
        if let predecessor { rows[.steps]!.insert(predecessor, at: 0) }
        var steps: [StepSample] = [], admitted: [Row] = [], rejected: [String] = [], gaps: [String] = []
        for row in rows[.steps]! {
            let id = try identity(row, stream: .steps)
            let provenance: ScalarProvenance?
            do {
                provenance = try ScalarProvenance.decodeJSON(row["provenanceJSON"] as String?)
                if let end = provenance?.inputEndTs, end > seed.input.asOfExclusive { throw V.failure("s12_future_step_provenance") }
            } catch {
                rejected.append(id.id); gaps.append("stepSample_provenance_invalid"); continue
            }
            let count: Int = row["counter"], activity: Int? = row["activityClass"]
            guard (0...65_535).contains(count), activity.map({ (0...2).contains($0) }) ?? true else {
                rejected.append(id.id); gaps.append("stepSample_measurement_invalid"); continue
            }
            if provenance == nil { gaps.append("stepSample_provenance_unknown") }
            steps.append(StepSample(ts: row["ts"], counter: count, activityClass: activity, provenance: provenance))
            admitted.append(row)
        }
        rows[.steps] = admitted
        var selected: [String: [V.StoredIdentity]] = [:]
        for stream in [C.Stream.hr, .gravity, .steps] { selected[stream.rawValue] = try rows[stream]!.map { try identity($0, stream: stream) } }
        let before = selected["steps"]!.first { $0.ts < window.startInclusive }
        let hr = rows[.hr]!.map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
        let gravity = try await seed.store.gravitySamples(deviceId: device, from: window.startInclusive,
            to: window.endExclusive - 1, limit: V.rowLimit + 1)
        if hr.isEmpty { gaps.append("cycle_hr_unavailable") }
        if steps.count < 2 { gaps.append("cycle_counter_pair_unavailable") }
        return Loaded(selected: selected, predecessor: before, rejectedStepIDs: rejected, hr: hr, gravity: gravity, steps: steps,
            gaps: Array(Set(gaps)).sorted())
    }

    static func evaluate(input: V.Input, seed: S.Seed, prepared: H.Prepared, sleep: Sleep.ResolvedSleep,
                         priorSleep: [PriorResolvedSleep] = []) async throws -> CycleEvidence {
        let b = try V.validate(input)
        guard input == seed.input, input == sleep.input, prepared.input == input.historyInput,
              input.historyCaseIds == priorSleep.map({ $0.input.id }), Set(input.historyCaseIds).count == priorSleep.count else {
            throw V.failure("s12_cycle_lineage")
        }
        var lastDay: String?
        for prior in priorSleep {
            guard prior.input.identity == input.identity, prior.input.day < input.day,
                  lastDay.map({ $0 < prior.input.day }) ?? true, prior.input.asOfExclusive <= input.asOfExclusive,
                  prior.inputDigest == (try C.digest(prior.input)) else { throw V.failure("s12_cycle_prior_scope") }
            lastDay = prior.input.day
        }
        let loaded = try await S.load(seed)
        let native = try Sleep.analyze(input: input, prepared: prepared, loaded: loaded, thermal: sleep.thermal, resolved: sleep)
        let zone = TimeZone(identifier: input.timezone)!
        let mode = DayCycleMode.persisted(try C.string(loaded.evidence.effectiveConfig, "dayCycleMode"))
        let blocks = native.sleepSessions.filter { $0.end > $0.start && $0.end <= input.asOfExclusive }.map { session in
            let entry = sleep.entries.first { $0.session.start == session.start && $0.session.end == session.end }!
            return PhysiologicalSteps.SleepBlock(onset: entry.identity.original.start, end: session.end, id: entry.identity.id,
                editedOnset: entry.identity.editEntity == nil ? nil : session.start, kind: entry.isNap == true ? .nap : .unclassified)
        }
        let classified = PhysiologicalSteps.classifyForCycle(blocks, offsetSec: b.tzOffsetSeconds,
            habitualMidsleepSec: prepared.habitualMidsleepSec, timezone: zone)
        let main = classified.filter { $0.kind == .mainSleep }.min { $0.effectiveOnset < $1.effectiveOnset }
        let current = main.map { block -> DayCycleWindow in
            let edited = sleep.entries.first { $0.identity.id == block.id }!.identity.editEntity != nil
            return DayCycleWindow(id: block.id, startInclusive: block.effectiveOnset, endExclusive: input.asOfExclusive,
                displayDay: input.day, source: edited ? .editedSleep : .detectedSleep)
        }
        // Keep the last own observed cycle only; changing source era does not adopt an old source's open cycle.
        let prior = priorSleep.last.flatMap { $0.sourceEra == prepared.policy.sourceEra && $0.window.source != "calendar" ? $0.window.native : nil }
        let latest = [current, prior].compactMap { $0 }.filter { $0.startInclusive < input.asOfExclusive }.max { $0.startInclusive < $1.startInclusive }
        let window = try mode == .midnight || latest == nil ? calendar(input)
            : DayCycleResolver.activeWindow(mode: mode, latestSleep: latest, now: input.asOfExclusive,
                offsetSec: b.tzOffsetSeconds, timezone: zone)
        let cycle = try await load(seed, window: window)
        var gaps = sleep.gaps + cycle.gaps
        let applies = window.displayDay == input.day
        if !applies { gaps.append("cycle_other_display_day") }
        if window.startInclusive < b.nightLo { gaps.append("cycle_extends_night_selection_explicit_store_query") }
        // Point measurements cannot prove continuous coverage; expose the observed span, never synthesize it.
        if cycle.hr.first.map({ $0.ts > window.startInclusive }) ?? true { gaps.append("cycle_hr_start_unobserved") }
        if cycle.hr.last.map({ $0.ts < window.endExclusive - 1 }) ?? true { gaps.append("cycle_hr_end_unobserved") }
        let profile = try Sleep.profile(loaded.evidence)
        let maxHR = try C.number(loaded.evidence.effectiveConfig, "maxHR") ?? (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)
        let restingHR = native.daily.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        let inWindowSteps = cycle.steps.filter { $0.ts >= window.startInclusive }
        let acc = SleepAwareStepCounter.Accumulator(sleepSessions: native.sleepSessions,
            hasActivityClasses: StepsCounter.hasActivityClasses(inWindowSteps))
        acc.observeMotion(gravityCount: cycle.gravity.count, auxCount: 0).acceptPage(cycle.steps)
        let count = acc.finish()
        let energy = cycle.hr.isEmpty ? nil : Energy(Calories.estimateDayEnergy(cycle.hr, profile: profile, hrmax: maxHR, restingHR: restingHR))
        let strain = cycle.hr.isEmpty ? nil : StrainScorer.strain(cycle.hr, maxHR: maxHR, restingHR: restingHR,
            method: prepared.policy.effortMethod == "BANISTER" ? .banister : .edwards, sex: profile.sex)
        let calendarMode = window.source == .calendar
        let steps = cycle.steps.count < 2 ? nil : Int((Double(count.totalTicks) / max(profile.stepTicksPerStep, 0.5)).rounded())
        let classification: [C.JSON] = classified.map { .object(["id": .string($0.id), "originalStart": .number(Double($0.onset)),
            "effectiveStart": .number(Double($0.effectiveOnset)), "end": .number(Double($0.end)),
            "kind": .string($0.kind == .mainSleep ? "main_sleep" : "nap")]) }
        let boundaries = [prior, current].compactMap { $0 }.map { PhysiologicalSteps.CycleBoundary(sleepId: $0.id, onset: $0.startInclusive) }
        return CycleEvidence(input: input, inputDigest: try C.digest(input), sourceEra: prepared.policy.sourceEra, mode: mode.rawValue,
            window: Window(window), openAtCutoff: !calendarMode, appliesToDay: applies, classification: .array(classification),
            boundaryWindows: try P.reflect(PhysiologicalSteps.cycleWindows(boundaries, now: input.asOfExclusive)),
            selected: cycle.selected, predecessor: cycle.predecessor, rejectedStepIDs: cycle.rejectedStepIDs,
            retainedByOwner: loaded.evidence.retainedByOwner, nativeDayResult: try P.reflect(native),
            counter: !calendarMode && applies && cycle.steps.count >= 2 ? try P.reflect(count) : nil,
            steps: !applies ? nil : calendarMode ? native.daily.steps : steps,
            strain: !applies ? nil : calendarMode ? native.strain : strain, energy: applies ? energy : nil,
            activeKcalEst: !applies ? nil : calendarMode ? native.daily.activeKcalEst : energy?.totalKcal,
            gaps: Array(Set(gaps)).sorted())
    }
}
