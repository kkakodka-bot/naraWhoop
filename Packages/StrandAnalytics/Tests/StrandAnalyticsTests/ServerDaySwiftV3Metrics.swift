import Foundation
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

/// S14 components over an admitted S13 execution. This is not whole-input admission.
enum ServerDaySwiftV3Metrics {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    typealias X = ServerDaySwiftV3Context
    typealias H = ServerDaySwiftHistory
    typealias S = ServerDaySwiftV3Selection
    typealias M = ServerDaySwiftV3Metadata
    typealias I = ServerDaySwiftV3Imports
    typealias W = ServerDaySwiftV3Workouts
    typealias P = ServerDaySwiftV3CoreProbe
    typealias Math = DailyPresentationMath

    struct Supplements: Encodable {
        let scope: M.Scope
        var originalJournalRows: [C.JournalRow] = []
        var legacyRows: [W.Legacy] = []
        var presentationPreferences: W.Presentation
        var auxiliaryEvidence: C.JSON? = nil
        init(_ context: X.Execution) {
            scope = M.Scope(context)
            let maxHR: Double?
            if case .number(let value) = context.observation.selection.effectiveConfig["maxHR"] { maxHR = value }
            else { maxHR = nil }
            presentationPreferences = .init(maxHR: maxHR, customZoneLowerBounds: nil, manualStepCoefficient: nil,
                inputRevision: context.observation.selection.configurationRevision, provenance: "s13_effective_configuration")
        }
    }
    struct NativeComponents: Encodable {
        let context: X.Execution
        let admittedDays: [DailyMetric]
        let readinessDays: [DailyMetric]
        let drivers: [ChargeDriver]
        let readiness: ReadinessEngine.Readiness
        let training: TrainingLoadEngine.Result
        let fitnessReadiness: FitnessAgeReadiness
        let fitness: FitnessAgeResult?
        let vitality: VitalityEngine.Result?
        let calibration: StepsEstimateEngine.Calibration?
        let calibrationPoints: [StepsEstimateEngine.CalibrationPoint]
        let dayMotion: Double
        let imports: I.Selection
        let workouts: W.Output
        let workoutDetection: C.JSON
        let activityCost: [ActivityCost]
        private enum CodingKeys: String, CodingKey {
            case context, admittedDays, readinessDays, drivers, readiness, training, fitnessReadiness
            case fitness, vitality, calibration, calibrationPoints, dayMotion, imports, workouts, workoutDetection, activityCost
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(context, forKey: .context)
            try c.encode(admittedDays, forKey: .admittedDays)
            try c.encode(readinessDays, forKey: .readinessDays)
            try c.encode(P.reflect(drivers), forKey: .drivers)
            try c.encode(C.JSON.object(["level": .string(readiness.level.rawValue), "headline": .string(readiness.headline),
                "summary": .string(readiness.summary), "acwr": M.number(readiness.acwr), "monotony": M.number(readiness.monotony),
                "confidence": .string(readiness.confidence.rawValue), "projectedSignals": M.readiness(readiness)]), forKey: .readiness)
            try c.encode(P.reflect(training), forKey: .training)
            try c.encode(P.reflect(fitnessReadiness), forKey: .fitnessReadiness)
            try c.encode(P.reflect(fitness as Any), forKey: .fitness)
            try c.encode(P.reflect(vitality as Any), forKey: .vitality)
            try c.encode(P.reflect(calibration as Any), forKey: .calibration)
            try c.encode(P.reflect(calibrationPoints), forKey: .calibrationPoints)
            try c.encode(M.number(dayMotion), forKey: .dayMotion)
            // Retained foreign rows are diagnostics, not admitted safe-integer scorer inputs.
            try c.encode(imports, forKey: .imports)
            try c.encode(workouts, forKey: .workouts)
            try c.encode(workoutDetection, forKey: .workoutDetection)
            try c.encode(P.reflect(activityCost), forKey: .activityCost)
        }
    }
    struct Execution: Encodable {
        let mode = "presentation_components_not_server_day"
        let native: NativeComponents
        let supplements: Supplements
        let combinedJournal: [C.JournalRow]
        let projection: M.Projection
        let history: [C.JSON]
        let parentDigest: String?
        let digest: String
        fileprivate init(native: NativeComponents, supplements: Supplements, combinedJournal: [C.JournalRow],
                         projection: M.Projection, history: [C.JSON], parentDigest: String?) throws {
            struct Seal: Encodable {
                let native: NativeComponents; let supplements: Supplements; let combinedJournal: [C.JournalRow]
                let projection: M.Projection; let history: [C.JSON]; let parentDigest: String?
            }
            self.native = native; self.supplements = supplements; self.combinedJournal = combinedJournal
            self.projection = projection; self.history = history; self.parentDigest = parentDigest
            digest = try C.digest(Seal(native: native, supplements: supplements, combinedJournal: combinedJournal,
                projection: projection, history: history, parentDigest: parentDigest))
        }
        var prior: Prior { Prior(self) }
    }
    struct Prior {
        fileprivate let execution: Execution
        fileprivate init(_ execution: Execution) { self.execution = execution }
    }

    static func evaluate(context: X.Execution, history: [X.Execution] = [], supplements: Supplements,
                         priorDetails: [Prior] = []) async throws -> Execution {
        let o = context.observation, input = o.input, day = input.day, d = o.native.daily
        guard supplements.scope == M.Scope(context), supplements.auxiliaryEvidence == nil,
              history.count == priorDetails.count, input.historyCaseIds == history.map({ $0.observation.input.id }),
              context.parentDigest == history.last?.digest else { throw M.failure("sidecar_lineage_or_unsupported_auxiliary") }
        try supplements.scope.validate(); try supplements.presentationPreferences.validate()
        var parent: String?, baseParent: String?, previousDay: String?
        for (index, previous) in history.enumerated() {
            let prior = priorDetails[index].execution, p = previous.observation.input
            guard prior.native.context.digest == previous.digest, prior.parentDigest == parent,
                  previous.parentDigest == baseParent, p.identity == input.identity, p.day < day,
                  previousDay.map({ $0 < p.day }) ?? true, p.asOfExclusive <= input.asOfExclusive,
                  p.historyCaseIds == Array(input.historyCaseIds.prefix(index)) else { throw M.failure("prior_execution_chain") }
            parent = prior.digest; baseParent = previous.digest; previousDay = p.day
        }
        var journal = input.journal
        for row in supplements.originalJournalRows where !journal.contains(row) { journal.append(row) }
        guard journal.count <= 10_000 else { throw M.failure("combined_journal_limit") }
        let base = try C.resolve(input.historyInput)
        let combined = try C.resolve(C.Input(identity: input.identity, day: day, timezone: input.timezone, raw: input.raw, journal: journal))
        func baseRows(_ resolution: C.Resolution) -> [C.JournalRow] {
            resolution.rows.filter { $0.kind != .importedDaily && $0.kind != .manualWorkout }
        }
        guard baseRows(base) == baseRows(combined) else { throw M.failure("supplement_changed_s13_owned_input") }
        let seed = try await S.seed(input), loaded = try await S.load(seed)
        guard loaded.evidence == o.selection else { throw M.failure("independent_store_selection_changed") }
        let profile = try userProfile(o.selection.effectiveProfile)
        let imports = try I.resolve(scope: supplements.scope, rows: journal, day: day)
        let importedView = try I.project(selection: imports, native: d, cycleUsesCalendar: o.cycle.window.source == "calendar")
        let cycleRaw = try await ServerDaySwiftV3Cycle.load(seed, window: o.cycle.window.native)
        let workoutEvaluation = try W.evaluate(resolved: W.resolve(scope: supplements.scope, rows: journal, legacy: supplements.legacyRows),
            raw: loaded, cycleRaw: cycleRaw, native: o.native, cycle: o.cycle, profile: profile, presentation: supplements.presentationPreferences)
        let own = history + [context]
        let admitted = try admit(own, current: context, readiness: false)
        let readinessRows = try admit(own, current: context, readiness: true).filter { $0.day >= (try! X.shift(day, -30)) }
        let readiness = try ReadinessEngine.evaluateCalendar(days: readinessRows, today: day)
        let training = TrainingLoadEngine.evaluate(days: admitted.map { .init(day: $0.day, load: $0.strain) }, through: day)
        let states = try o.checkpoint.observation.baselinesBefore.mapValues { try $0.native() }
        let perf = o.native.restScore.map { $0 / 100 } ?? d.efficiency
        let drivers: [ChargeDriver]
        if let hrv = d.avgHrv, let rhr = d.restingHr, let hrvState = states["hrv"] {
            drivers = RecoveryScorer.chargeDrivers(hrv: hrv, rhr: Double(rhr), resp: d.respRateBpm,
                hrvBaseline: hrvState, rhrBaseline: states["resting_hr"], respBaseline: states["resp"],
                sleepPerf: perf, skinTempDev: d.skinTempDevC)
        } else { drivers = [] }
        let seven = admitted.filter { $0.day >= (try! X.shift(day, -6)) }
        let rhrs = seven.compactMap { $0.restingHr.map(Double.init) }, strains = seven.compactMap(\.strain)
        let p = base.payload(.profile), age = try optionalNumber(p["age"]), sex = try optionalString(p["sex"])
        let waist = try optionalNumber(p["waistCm"])
        let fitnessReadiness = FitnessAgeEngine.assessReadiness(hasAge: age != nil, hasSex: sex != nil,
            rhrDays: rhrs.count, activityDays: strains.count, hasHeightWeight: p["heightCm"] != nil && p["weightKg"] != nil,
            hasWaist: waist.map { $0 > 0 } ?? false)
        let active = strains.filter { $0 >= 30 }
        let pa = FitnessAgeEngine.physicalActivityIndexFromStrain(activeDaysPerWeek: active.count,
            meanActiveStrain: Math.mean(active) ?? 0)
        let medianRhr = rhrs.isEmpty ? nil : StepsEstimateEngine.median(rhrs)
        let current = admitted.last!
        let fitness: FitnessAgeResult? = fitnessReadiness.canCompute && (current.restingHr != nil || current.strain != nil)
            ? medianRhr.flatMap { FitnessAgeEngine.compute(age: profile.age, sex: profile.sex, restingHR: $0, paIndex: pa,
                waistCm: waist) } : nil
        let vo2 = fitness?.vo2max ?? (fitness != nil ? medianRhr.flatMap {
            Calories.vo2maxFor(hrmax: StrainScorer.estimateHRmax([], age: profile.age).0, restingHR: $0)
        } : nil)
        let sleepHours = seven.compactMap { $0.totalSleepMin.flatMap { $0 > 0 ? $0 / 60 : nil } }
        let hasCurrentVitality = current.restingHr != nil || current.avgHrv != nil || current.totalSleepMin != nil || current.steps != nil
        let hrvs = seven.compactMap(\.avgHrv)
        let vitality = hasCurrentVitality && age != nil ? VitalityEngine.compute(.init(chronoAge: profile.age,
            restingHR: medianRhr, sleepHours: Math.mean(sleepHours),
            sleepConsistency: VitalityEngine.sleepConsistency(nightlyHours: sleepHours), rmssd: hrvs.isEmpty ? nil : StepsEstimateEngine.median(hrvs),
            rmssdNorm: VitalityEngine.rmssdNorm(forAge: profile.age), steps: Math.mean(seven.compactMap { $0.steps.map(Double.init) }))) : nil
        let eligiblePriors = priorDetails.map(\.execution).filter {
            $0.native.context.observation.checkpoint.policy.sourceEra == o.checkpoint.policy.sourceEra
        }
        let fitFrom = try X.shift(day, -60)
        let points = eligiblePriors.filter { $0.native.context.observation.input.day >= fitFrom }.compactMap { prior -> StepsEstimateEngine.CalibrationPoint? in
            guard let reading = prior.native.imports.selected["steps_count"], [.apple, .healthConnect].contains(reading.source.kind) else { return nil }
            return .init(motion: prior.native.dayMotion, steps: reading.value)
        }
        let calibration = StepsEstimateEngine.calibrate(points, manualOverride: supplements.presentationPreferences.manualStepCoefficient)
        let dayGrav = loaded.gravity.filter { $0.ts >= o.selection.bounds.dayLo && $0.ts <= o.selection.bounds.dayHi }
        let motion = StepsEstimateEngine.dayMotionIntensity(dayGrav)
        if let c = calibration, !((motion * c.coefficient).isFinite && motion * c.coefficient < Double(Int.max)) {
            throw M.failure("step_estimate_numeric_range")
        }
        var sports: [String: Set<String>] = [:]
        for prior in eligiblePriors {
            for session in prior.native.workouts.sessions {
                let object = try V.object(session), sport = try V.string(object["sport"])
                sports[sport, default: []].insert(prior.native.context.observation.input.day)
            }
        }
        var recoveries: [String: Double] = [:]
        for row in admitted { if let recovery = row.recovery { recoveries[row.day] = recovery } }
        let cost = ActivityCostEngine.evaluate(activityDaysBySport: sports, recoveryByDay: recoveries)
        let native = NativeComponents(context: context, admittedDays: admitted, readinessDays: readinessRows, drivers: drivers,
            readiness: readiness, training: training, fitnessReadiness: fitnessReadiness, fitness: fitness, vitality: vitality,
            calibration: calibration, calibrationPoints: points, dayMotion: motion, imports: imports,
            workouts: workoutEvaluation.output, workoutDetection: workoutEvaluation.detectionFunnel, activityCost: cost)
        let projection = try project(native, loaded: loaded, history: history, imported: importedView,
                                     preferences: supplements.presentationPreferences, vo2: vo2)
        let historyProjection = try priorDetails.suffix(30).map { prior in
            C.JSON.object(["day": .string(prior.execution.native.context.observation.input.day), "metrics": try V.json(prior.execution.projection.metrics)])
        }
        return try Execution(native: native, supplements: supplements, combinedJournal: journal, projection: projection,
                             history: historyProjection, parentDigest: parent)
    }

    static func userProfile(_ p: [String: C.JSON]) throws -> UserProfile {
        try UserProfile(weightKg: V.number(p["weightKg"]), heightCm: V.number(p["heightCm"]), age: V.number(p["age"]),
            sex: V.string(p["sex"]), stepTicksPerStep: V.number(p["stepTicksPerStep"]))
    }
    static func optionalNumber(_ value: C.JSON?) throws -> Double? { value == nil || value == .null ? nil : try V.number(value) }
    static func optionalString(_ value: C.JSON?) throws -> String? { value == nil || value == .null ? nil : try V.string(value) }

    /// UTC day-key reset policy is an admission view, not a physiological transform.
    static func admit(_ executions: [X.Execution], current: X.Execution, readiness: Bool) throws -> [DailyMetric] {
        let checkpoint = current.observation.checkpoint, policy = checkpoint.policy
        let before = try checkpoint.observation.baselinesBefore.mapValues { try $0.native() }
        return try executions.filter { $0.observation.checkpoint.policy.sourceEra == policy.sourceEra }.map { execution in
            let d = execution.observation.native.daily, keyTs = Double(try C.dayBounds(d.day, "UTC").lowerBound)
            func allow(_ metric: String, usable: Bool = true) -> Bool {
                keyTs >= policy.epoch(metric) && (!usable || before[metric]?.usable == true)
            }
            let hrv = allow("hrv") && (!readiness || allow("readiness_hrv_ln"))
            let recovered = allow("recovery", usable: false), strain = allow("strain", usable: false) &&
                execution.observation.checkpoint.policy.effortMethod == policy.effortMethod
            return DailyMetric(day: d.day, totalSleepMin: recovered ? d.totalSleepMin : nil, efficiency: d.efficiency,
                deepMin: d.deepMin, remMin: d.remMin, lightMin: d.lightMin, disturbances: d.disturbances,
                restingHr: allow("resting_hr") ? d.restingHr : nil, avgHrv: hrv ? d.avgHrv : nil,
                recovery: recovered ? d.recovery : nil, strain: strain ? execution.observation.cycle.strain : nil, exerciseCount: d.exerciseCount,
                spo2Pct: d.spo2Pct, skinTempDevC: d.skinTempDevC, respRateBpm: allow("resp") ? d.respRateBpm : nil,
                steps: recovered ? d.steps : nil, activeKcalEst: d.activeKcalEst, spo2Red: d.spo2Red, spo2Ir: d.spo2Ir,
                avgSdnn: d.avgSdnn, skinTempC: d.skinTempC, sleepHrOnly: d.sleepHrOnly)
        }
    }

    static func project(_ n: NativeComponents, loaded: S.Loaded, history: [X.Execution], imported: I.Projection,
                        preferences: W.Presentation, vo2: Double?) throws -> M.Projection {
        let x = n.context, o = x.observation, d = o.native.daily, input = o.input, day = input.day, policy = o.checkpoint.policy
        let prior = Array(n.admittedDays.dropLast()), before = try o.checkpoint.observation.baselinesBefore.mapValues { try $0.native() }
        let prepared = try H.prepare(input.historyInput, history: history.map { $0.observation.checkpoint.observation })
        let descriptiveNeed = Math.descriptiveSleepNeed(observedMinutes: prior.map(\.totalSleepMin))
        let profile = try userProfile(o.selection.effectiveProfile), zones = try preferences.zones(age: profile.age)
        let dayHR = loaded.hr.filter { $0.ts >= o.selection.bounds.dayLo && $0.ts <= o.selection.bounds.dayHi && $0.bpm > 0 }
        let zoneSeconds = dayHR.isEmpty ? nil : HRZones.timeInZone(dayHR, zoneSet: zones).seconds
        let calendarCycle = o.cycle.window.source == "calendar", method = policy.effortMethod.lowercased()
        var metrics: [String: M.Reading] = [:]
        func put(_ key: String, _ value: Double?, _ unit: String, _ method: String) throws {
            try M.insert(key, M.Reading(value: value, unit: unit, method: .native(method)), into: &metrics)
        }
        try put("hrv_rmssd_ms", d.avgHrv, "ms", "nightly_rr_rmssd")
        try put("hrv_sdnn_ms", d.avgSdnn, "ms", "nightly_rr_sdnn")
        try put("resting_hr_bpm", d.restingHr.map(Double.init), "bpm", "nightly_rolling_floor")
        try put("resp_rate_bpm", d.respRateBpm, "breaths/min", "nightly_respiration")
        try put("recovery", d.recovery, "score_0_100", "charge_ewma_asof")
        try put("strain", o.cycle.strain, "score_0_100", (calendarCycle ? "daily_" : "asof_cycle_") + method)
        try put("exercise_count", n.workouts.count.map(Double.init), "count", "resolved_workout_set")
        try put("steps", o.cycle.steps.map(Double.init), "count", calendarCycle ? "strap_counter_calibrated_ticks" : "asof_cycle_sleep_aware_counter")
        try put("active_kcal_est", o.cycle.activeKcalEst, "kcal", calendarCycle ? "hr_energy_estimate" : "asof_cycle_hr_energy_estimate")
        try put("spo2_pct", d.spo2Pct, "percent", "measured_percentage")
        try put("spo2_red", d.spo2Red.map(Double.init), "adc", "raw_red_adc")
        try put("spo2_ir", d.spo2Ir.map(Double.init), "adc", "raw_ir_adc")
        let family = o.thermal.anchor.family
        guard ["whoop4", "whoop5", "oura"].contains(family) else { throw M.failure("skin_family") }
        try put("skin_temp_c", o.native.nightlySkinTempC, "C", family + "_worn_skin")
        try put("skin_temp_dev_c", d.skinTempDevC, "C", "personal_skin_baseline_deviation")
        for (key, value) in [("sleep_total_min", d.totalSleepMin), ("sleep_light_min", d.lightMin), ("sleep_deep_min", d.deepMin), ("sleep_rem_min", d.remMin)] {
            try put(key, value, "min", "main_night_stages")
        }
        try put("disturbances", d.disturbances.map(Double.init), "count", "main_night_stages")
        try put("sleep_efficiency", Math.efficiencyPercent(d.efficiency), "percent", "observed_asleep_over_in_bed")
        try put("sleep_performance", o.native.restScore, "score_0_100", "rest_composite_asof")
        try put("sleep_need_min", o.checkpoint.needHours * 60, "min", "normative_upper_quartile_age_floor")
        try put("hours_vs_needed_pct", Math.hoursVsNeededPercent(asleepMin: d.totalSleepMin, needMin: descriptiveNeed), "percent", "descriptive_mean_need_floor_450")
        try put("restorative_min", Math.restorativeMinutes(deepMin: d.deepMin, remMin: d.remMin), "min", "deep_plus_rem")
        try put("restorative_pct", Math.restorativePercent(deepMin: d.deepMin, remMin: d.remMin, asleepMin: d.totalSleepMin), "percent", "deep_plus_rem_over_asleep")
        let debt = o.checkpoint.sleepDebt
        try put("sleep_debt_min", debt.nightCount > 0 ? debt.magnitudeMin : nil, "min", "sleep_debt_14_usable_nights")
        let bedMinutes = (history + [x]).filter { $0.observation.checkpoint.policy.sourceEra == policy.sourceEra }.flatMap { execution -> [Double] in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: execution.observation.input.timezone)!
            return execution.observation.checkpoint.observation.measurements.sleep.map { block in
                let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: Double(block.start)))
                return Double(c.hour! * 60 + c.minute!)
            }
        }
        let hasCurrentBedtime = !o.checkpoint.observation.measurements.sleep.isEmpty
        try put("sleep_consistency", hasCurrentBedtime ? Math.bedtimeConsistencySeries(localBedMinutes: bedMinutes).last : nil,
                "percent", "rolling_14_bedtime_spread")
        try put("acwr", n.readiness.acwr, "ratio", "readiness_7_28_calendar_suffix")
        try put("training_monotony", n.readiness.monotony, "ratio", "foster_calendar_suffix_week")
        try put("chronic_load", n.training.chronicLoad, "score_0_100", "ewma_42d_" + method)
        try put("acute_load", n.training.acuteLoad, "score_0_100", "ewma_7d_" + method)
        try put("training_balance", n.training.balance, "score_delta", "chronic_minus_acute")
        try put("fitness_age", n.fitness?.fitnessAge, "years", "nes_hunt_activity")
        try put("vo2max_est", vo2, "mL/kg/min", n.fitness?.vo2max == nil ? "uth_hr_ratio" : "nes_waist")
        try put("vitality", n.vitality?.vitality, "score_0_100", "vitality_existing_hazard_model")
        try put("body_age", n.vitality?.bodyAge, "years", "vitality_existing_hazard_model")
        try put("avg_hr", Math.mean(dayHR.map { Double($0.bpm) }), "bpm", "calendar_day_observed_hr")
        try put("max_hr", dayHR.map(\.bpm).max().map(Double.init), "bpm", "calendar_day_observed_hr")
        try put("hr_zones13_min", zoneSeconds.map { $0.prefix(3).reduce(0, +) / 60 }, "min", "hrmax_display_zones")
        try put("hr_zones45_min", zoneSeconds.map { $0.suffix(2).reduce(0, +) / 60 }, "min", "hrmax_display_zones")
        try put("hr_zones_all_min", zoneSeconds.map { $0.reduce(0, +) / 60 }, "min", "hrmax_display_zones")
        try put("strength_min", n.workouts.strengthMin, "min", "explicit_strength_workout_bounds")
        try put("steps_est", n.calibration.flatMap { StepsEstimateEngine.estimate(motion: n.dayMotion, calibration: $0) }.map(Double.init), "count", "personal_motion_phone_steps_calibration")
        let stressFrom = try X.shift(day, -30), stressPrior = prior.filter { $0.day >= stressFrom }, current = n.admittedDays.last!
        let rhrs = stressPrior.compactMap { $0.restingHr.map(Double.init) }, hrvs = stressPrior.compactMap(\.avgHrv)
        let meanRhr = Math.mean(rhrs), meanHrv = Math.mean(hrvs)
        let canStress = current.restingHr != nil && !rhrs.isEmpty || current.avgHrv != nil && !hrvs.isEmpty
        let stress = canStress ? Math.dailyStressSquash(Math.dailyStressRaw(rhrToday: current.restingHr.map(Double.init),
            meanRHR: meanRhr, sdRHR: Math.populationSD(rhrs, mean: meanRhr), hrvToday: current.avgHrv,
            meanHRV: meanHrv, sdHRV: Math.populationSD(hrvs, mean: meanHrv))) : nil
        try put("stress", stress, "score_0_3", "daily_prior30_rhr_hrv_zsum")
        for (key, reading) in x.output.metrics { try put(key, reading.value, reading.unit, reading.method) }
        guard Set(metrics.keys) == M.nativeKeys else { throw M.failure("native_scalar_inventory") }
        for (key, reading) in imported.metrics { metrics[key] = reading }

        var details = try V.object(x.output.details)
        func detail(_ key: String, _ json: C.JSON) throws { try M.insert(key, json, into: &details) }
        let values: [String: Double?] = ["hrv": d.avgHrv, "resting_hr": d.restingHr.map(Double.init), "resp": d.respRateBpm, "skin_temp": o.native.nightlySkinTempC]
        var baselines: [String: C.JSON] = [:]
        for (key, state) in before {
            let deviation = values[key].flatMap { $0 }.flatMap { state.usable ? Baselines.deviation($0, state: state) : nil }
            baselines[key] = .object(["baseline": M.number(state.baseline), "spread": M.number(state.spread),
                "nValid": M.integer(state.nValid), "nightsSinceUpdate": M.integer(state.nightsSinceUpdate), "status": .string(state.status.rawValue),
                "z": M.number(deviation?.z), "delta": M.number(deviation?.delta), "ratio": M.number(deviation?.ratio),
                "normalLow": M.number(state.baseline - Baselines.sigma(state)), "normalHigh": M.number(state.baseline + Baselines.sigma(state))])
        }
        try detail("baselines", .object(baselines))
        let perf = o.native.restScore.map { $0 / 100 } ?? d.efficiency
        try detail("charge", M.charge(n.drivers, values: ["heart_rate_variability": (d.avgHrv, before["hrv"]?.baseline),
            "resting_heart_rate": (d.restingHr.map(Double.init), before["resting_hr"]?.baseline),
            "respiratory_rate": (d.respRateBpm, before["resp"]?.baseline), "sleep_quality": (perf.map { $0 * 100 }, nil),
            "skin_temperature": (d.skinTempDevC, nil)], confidence: o.native.chargeConfidence.rawValue))
        try detail("effort", .object(["confidence": .string(o.native.effortConfidence.rawValue), "method": .string(policy.effortMethod)]))
        try detail("rest", .object(["confidence": .string(o.native.restConfidence.rawValue),
            "gravitySparse": .bool(SleepStager.isGravitySparse(loaded.gravity, hr: loaded.hr)), "hrOnly": .bool(d.sleepHrOnly == true)]))
        try detail("sleep_ledger", .object(["needMin": M.number(debt.needMin), "balanceMin": M.number(debt.balanceMin),
            "nightCount": M.integer(debt.nightCount), "descriptiveNeedMin": M.number(descriptiveNeed),
            "restDurationConsistency": M.number(prepared.consistency), "habitualMidsleepSec": M.integer(prepared.habitualMidsleepSec), "nights": try V.json(debt.nights)]))
        try detail("sleep_typicals", .object(["method": .string("strictly_prior_observed_nights"),
            "asleepMin": M.number(Math.positiveMean(prior.map(\.totalSleepMin))), "deepMin": M.number(Math.positiveMean(prior.map(\.deepMin))),
            "remMin": M.number(Math.positiveMean(prior.map(\.remMin))), "lightMin": M.number(Math.positiveMean(prior.map(\.lightMin)))]))
        let sleep = try sleepDetails(context: x, loaded: loaded)
        try detail("sleep_sessions", .array(sleep.sessions))
        try detail("readiness", M.readiness(n.readiness)); try detail("training_load", M.training(n.training))
        let week = try weekKey(day)
        let confidence: [FitnessAgeConfidence: String] = [.ready: "ready", .estimate: "estimate", .notReady: "not_ready"]
        try detail("fitness_age", .object(["weekKey": .string(week), "asOfDay": .string(day),
            "confidence": .string(confidence[n.fitnessReadiness.confidence]!), "bandYears": M.number(FitnessAgeEngine.displayBandYears),
            "lowerConfidence": .bool(n.fitness?.lowerConfidence ?? true), "inputs": .array(n.fitnessReadiness.items.map {
                .object(["key": .string($0.key), "status": .string($0.status.rawValue), "required": .bool($0.required),
                    "role": .string($0.role == .drivesAge ? "drives_age" : "unlocks_vo2max")])
            })]))
        try detail("vitality", .object(["weekKey": .string(week), "asOfDay": .string(day), "factorsUsed": M.integer(n.vitality?.factorsUsed ?? 0),
            "bandYears": M.number(VitalityEngine.bandYears), "contributions": .array((n.vitality?.contributions ?? []).map {
                .object(["key": .string($0.key), "lnHazard": M.number($0.lnHazard)])
            })]))
        try detail("hr_zones", .object(["maxHR": M.number(zones.maxHR), "source": .string(zones.source),
            "lowerBounds": try P.reflect(zones.zones.map(\.lower)), "seconds": try P.reflect(zoneSeconds as Any)]))
        try detail("workouts", .array(n.workouts.sessions)); try detail("workout_detection", n.workoutDetection)
        try detail("activity_cost", .array(n.activityCost.map { .object(["sport": .string($0.sport), "delta": M.number($0.delta),
            "meanNextMorning": M.number($0.meanNextMorning), "baselineMean": M.number($0.baselineMean),
            "daysToBaseline": M.integer($0.daysToBaseline), "sampleDays": M.integer($0.n), "confidence": .string($0.confidence.rawValue)]) }))
        try detail("step_calibration", .object(["sampleDays": M.integer(n.calibration?.sampleDays ?? n.calibrationPoints.count),
            "coefficient": M.number(n.calibration?.coefficient), "confidence": M.number(n.calibration?.confidence),
            "manual": .bool(n.calibration?.manual ?? false), "dayMotion": M.number(n.dayMotion)]))
        try detail("imported_provenance", .object(imported.provenance))
        try detail("skin_calibration", .object(["family": .string(family), "anchorRaw": M.number(o.thermal.anchor.resolvedRaw),
            "asOfDay": .string(day), "method": .string(family == "whoop4" ? "asof_21_day_window_worn_raw_median" : "centidegree_raw"),
            "priorThermalBaselineCommonScale": .bool(family == "whoop4"), "relative": .bool(family == "whoop4")]))
        try detail("day_cycle", cycleDetail(o.cycle))
        let diagnostic = try inputDiagnostics(loaded)
        try detail("input_provenance", diagnostic.provenance); try detail("derived_ppg_hr", diagnostic.derived)
        var charts = try V.object(x.output.charts), chartMetadata: [String: C.JSON] = [:]
        for key in charts.keys {
            charts[key] = .array(Array(try V.array(charts[key]!).suffix(180)))
            chartMetadata[key] = .object(["schemaVersion": .number(1), "method": .string("existing_context_engine")])
        }
        func chart(_ key: String, _ value: C.JSON, _ metadata: C.JSON) throws {
            try M.insert(key, value, into: &charts); try M.insert(key, metadata, into: &chartMetadata)
        }
        try chart("day_hr", V.json(M.buckets(dayHR.map { ($0.ts, Double($0.bpm)) }, from: o.selection.bounds.dayLo, to: input.asOfExclusive)), M.chartMetadata(unit: "bpm"))
        for key in sleep.charts.keys { try chart(key, sleep.charts[key]!, sleep.metadata[key]!) }
        var derivedMeta = try V.object(M.chartMetadata(unit: "bpm", method: "uploaded_ppg_estimate_observed_mean"))
        derivedMeta["measured"] = .bool(false); derivedMeta["measuredHrWinsOverlap"] = .bool(true)
        try chart("derived_ppg_hr", V.json(M.buckets(diagnostic.ppg.map { ($0.ts, Double($0.bpm)) }, from: o.selection.bounds.dayLo, to: input.asOfExclusive)), .object(derivedMeta))
        guard Set(details.keys) == M.detailKeys else { throw M.failure("complete_detail_inventory") }
        return try M.project(metrics: metrics, details: details, charts: charts, chartMetadata: chartMetadata,
            capabilities: x.output.capabilities + ["s14_native_components", "s14_supplied_import_view", "s14_workout_details"],
            gaps: x.output.gaps + o.cycle.gaps + n.workouts.gaps + ["whole_combined_input_not_admitted", "elevation_not_in_current_input_contract", "auxiliary_and_oura_full_input_seam_unavailable"])
    }

    static func weekKey(_ day: String) throws -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: Double(try C.dayBounds(day, "UTC").lowerBound))
        return try X.shift(day, -(calendar.component(.weekday, from: date) % 7))
    }

    static func cycleDetail(_ c: ServerDaySwiftV3Cycle.CycleEvidence) -> C.JSON {
        .object(["mode": .string(c.mode), "source": .string(c.window.source), "id": .string(c.window.id),
            "startInclusive": M.integer(c.window.startInclusive), "endExclusive": M.integer(c.window.endExclusive),
            "displayDay": .string(c.window.displayDay), "asOfDay": .string(c.input.day), "openAsOfCutoff": .bool(c.openAtCutoff),
            "counter": c.counter ?? .null])
    }

    struct SleepDetails {
        var sessions: [C.JSON] = []
        var charts: [String: C.JSON] = [:]
        var metadata: [String: C.JSON] = [:]
    }
    static func sleepDetails(context: X.Execution, loaded: S.Loaded) throws -> SleepDetails {
        var result = SleepDetails()
        let native = context.observation.native
        for entry in context.observation.sleep.entries {
            let s = entry.session.native, id = entry.identity.id, stages = s.stages
            let staged = stages.reduce(0) { $0 + $1.end - $1.start }, span = s.end - s.start
            let hr = loaded.hr.filter { $0.ts >= s.start && $0.ts < s.end && $0.bpm > 0 }
            let gravity = loaded.gravity.filter { $0.ts >= s.start && $0.ts < s.end }
            let h = stages.isEmpty ? nil : SleepStager.hypnogramMetrics(s)
            let hypnogram: C.JSON = h.map { .object(["inBedS": M.number($0.tibS), "asleepS": M.number($0.tstS),
                "sleepPeriodS": M.number($0.sptS), "sleepLatencyS": M.number($0.solS),
                "remLatencyS": M.number($0.remLatencyS.isFinite ? $0.remLatencyS : nil),
                "wakeAfterSleepOnsetS": M.number($0.wasoS), "disturbances": M.integer($0.disturbances)]) } ?? .null
            var motion: C.JSON = .null
            if let values = native.sessionMotionByStart[s.start] {
                let counts = (0..<values.count).map { i in gravity.filter { $0.ts >= s.start + i * 30 && $0.ts < s.start + (i + 1) * 30 }.count }
                motion = .object(["start": M.integer(s.start), "epochSeconds": .number(30), "unit": .string("gravity_delta_sum"),
                    "method": .string("existing_stager_epoch_motion_observed_mask"),
                    "values": .array(values.indices.map { counts[$0] > 0 ? M.number(values[$0]) : .null }), "counts": try P.reflect(counts)])
            }
            let band: C.JSON = try native.sessionSleepStateByStart[s.start].map {
                .object(["start": M.integer(s.start), "epochSeconds": .number(30), "values": try P.reflect($0),
                    "method": .string("existing_raw_band_state_epochs"), "isDerivedStage": .bool(false)])
            } ?? .null
            let insights = ["wake", "light", "deep", "rem"].map { stage -> C.JSON in
                let segments = stages.filter { $0.stage == stage }
                let values = hr.filter { h in segments.contains { $0.start <= h.ts && h.ts < $0.end } }
                return .object(["stage": .string(stage), "durationS": stages.isEmpty ? .null : M.integer(segments.reduce(0) { $0 + $1.end - $1.start }),
                    "hrSampleCount": M.integer(values.count), "meanHr": M.number(Math.mean(values.map { Double($0.bpm) }))])
            }
            result.sessions.append(.object(["id": .string(id), "editEntity": entry.identity.editEntity.map(C.JSON.string) ?? .null,
                "start": M.integer(s.start), "end": M.integer(s.end), "isNap": .bool(entry.isNap ?? !(context.observation.mainNight?.originalIDs.contains(id) ?? false)),
                "hrOnly": .bool(s.hrOnly), "stagingSparse": .bool(native.cachedSleep.first { $0.startTs == s.start }?.stagingSparse ?? false),
                "stagedSeconds": M.integer(staged), "stageCoverage": span > 0 ? M.number(Double(staged) / Double(span)) : .null,
                "hypnogram": hypnogram, "motion": motion, "bandState": band, "stageInsights": .array(insights)]))
            result.charts["sleep_hr:" + id] = try V.json(M.buckets(hr.map { ($0.ts, Double($0.bpm)) }, from: s.start, to: s.end))
            result.metadata["sleep_hr:" + id] = M.chartMetadata(unit: "bpm", session: id)
            let activity = WorkoutDetector.activitySeries(gravity)
            result.charts["sleep_motion:" + id] = try V.json(M.buckets(activity.map { ($0.ts, $0.intensity) }, from: s.start, to: s.end))
            result.metadata["sleep_motion:" + id] = M.chartMetadata(unit: "gravity_delta", session: id, signal: "consecutive_gravity_l2_delta")
        }
        return result
    }

    struct InputDiagnostics { let provenance: C.JSON; let derived: C.JSON; let ppg: [PpgHrSample] }
    static func inputDiagnostics(_ loaded: S.Loaded) throws -> InputDiagnostics {
        var streams: [String: C.JSON] = [:]
        for name in ["steps", "bandState", "ppgHr"] {
            let rows = loaded.evidence.streams[name, default: []]
            var known = 0, origins = Set<String>(), algorithms = Set<String>()
            for row in rows {
                guard let payload = row.fields["provenance"], payload != .null else { continue }
                let provenance = try JSONDecoder().decode(ScalarProvenance.self, from: C.bytes(payload))
                known += 1; origins.insert(provenance.origin.rawValue)
                if let algorithm = provenance.algorithm { algorithms.insert(algorithm.rawValue) }
            }
            streams[name] = .object(["samples": M.integer(rows.count), "known": M.integer(known), "unknown": M.integer(rows.count - known),
                "origins": .array(origins.sorted().map(C.JSON.string)), "algorithms": .array(algorithms.sorted().map(C.JSON.string))])
        }
        let measured = Set(loaded.hr.map(\.ts)), ppg = loaded.ppgHr.filter {
            !measured.contains($0.ts) && loaded.evidence.bounds.dayRange.contains($0.ts)
        }
        return InputDiagnostics(provenance: .object(["schemaVersion": .number(1), "streams": .object(streams)]),
            derived: .object(["method": .string("uploaded_ppg_estimate_not_measured_hr"), "admittedToNightPhysiology": .bool(false), "usedForRrHrv": .bool(false),
                "samplesAfterMeasuredOverlap": M.integer(ppg.count), "unknownConfidence": M.integer(ppg.filter { !$0.conf.isFinite }.count)]), ppg: ppg)
    }
}
