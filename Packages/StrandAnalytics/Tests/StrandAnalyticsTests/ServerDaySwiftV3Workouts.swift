import CryptoKit
import Foundation
import WhoopProtocol
@testable import StrandAnalytics

enum ServerDaySwiftV3Workouts {
    typealias C = ServerDaySwiftContract
    typealias V = ServerDaySwiftV3Contract
    typealias S = ServerDaySwiftV3Selection
    typealias Cycle = ServerDaySwiftV3Cycle
    typealias M = ServerDaySwiftV3Metadata
    typealias P = ServerDaySwiftV3CoreProbe

    struct Presentation: Encodable, Equatable {
        let maxHR: Double?
        let customZoneLowerBounds: [Double]?
        let manualStepCoefficient: Double?
        let inputRevision: Int64
        let provenance: String
        func validate() throws {
            guard inputRevision >= 0, Double(inputRevision) <= C.safeInteger, !provenance.isEmpty,
                  inputRevision > 0 || (maxHR == nil && customZoneLowerBounds == nil && manualStepCoefficient == nil),
                  maxHR.map({ $0.isFinite && (80...240).contains($0) }) ?? true,
                  manualStepCoefficient.map({ $0.isFinite && $0 > 0 && $0 <= 1_000_000 }) ?? true else { throw M.failure("presentation_input") }
            if let customZoneLowerBounds {
                guard customZoneLowerBounds.count == 5, customZoneLowerBounds.allSatisfy({ $0.isFinite && (30...250).contains($0) }),
                      zip(customZoneLowerBounds, customZoneLowerBounds.dropFirst()).allSatisfy({ $0 < $1 }) else {
                    throw M.failure("presentation_zones")
                }
            }
        }
        func zones(age: Double) throws -> HRZoneSet {
            try validate()
            let maxHR = maxHR ?? HRZones.tanakaMaxHR(age: age).rounded()
            return HRZones.zones(maxHR: maxHR, source: self.maxHR == nil ? "tanaka" : "manual",
                                 customLowerBounds: customZoneLowerBounds)
        }
    }
    struct Legacy: Encodable, Equatable {
        let owner: UUID
        let device: UUID
        let id: UUID
        let start: Int
        let end: Int
        let sport: String
        let source: String
        let userModified: Bool
        let energyKcal: Double?
        let distanceM: Double?
        let steps: Int?
        let updatedAt: Int
        let algorithmIsServerOwned: Bool

        private enum CodingKeys: String, CodingKey {
            case owner, device, id, start, end, sport, source, userModified
            case energyKcal, distanceM, steps, updatedAt, algorithmIsServerOwned
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(owner, forKey: .owner)
            try c.encode(device, forKey: .device)
            try c.encode(id, forKey: .id)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
            try c.encode(sport, forKey: .sport)
            try c.encode(source, forKey: .source)
            try c.encode(userModified, forKey: .userModified)
            try c.encode(energyKcal, forKey: .energyKcal)
            try c.encode(distanceM, forKey: .distanceM)
            try c.encode(steps, forKey: .steps)
            try c.encode(updatedAt, forKey: .updatedAt)
            try c.encode(algorithmIsServerOwned, forKey: .algorithmIsServerOwned)
        }
    }
    struct Entry: Encodable, Equatable {
        let entity: String
        let originalStart: Int
        let originalSport: String
        let start: Int
        let end: Int
        let sport: String
        let dismissed: Bool
        let manual: Bool
        let legacySource: String?
        let energyKcal: Double?
        let distanceM: Double?
        let steps: Int?
        let inputRevision: Int64?

        private enum CodingKeys: String, CodingKey {
            case entity, originalStart, originalSport, start, end, sport, dismissed, manual
            case legacySource, energyKcal, distanceM, steps, inputRevision
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(entity, forKey: .entity)
            try c.encode(originalStart, forKey: .originalStart)
            try c.encode(originalSport, forKey: .originalSport)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
            try c.encode(sport, forKey: .sport)
            try c.encode(dismissed, forKey: .dismissed)
            try c.encode(manual, forKey: .manual)
            try c.encode(legacySource, forKey: .legacySource)
            try c.encode(energyKcal, forKey: .energyKcal)
            try c.encode(distanceM, forKey: .distanceM)
            try c.encode(steps, forKey: .steps)
            try c.encode(inputRevision, forKey: .inputRevision)
        }
    }
    struct Resolution: Encodable, Equatable {
        let scope: M.Scope
        let originalRows: [C.JournalRow]
        let originalLegacy: [Legacy]
        let manual: [Entry]
        let legacy: [Entry]
        let retainedTombstones: [C.JournalRow]
    }
    struct Output: Encodable, Equatable {
        let resolution: Resolution
        let sessions: [C.JSON]
        let count: Int?
        let strengthMin: Double?
        let selectedHrIDs: [String: [String]]
        let rejectedEntries: [String]
        let gaps: [String]

        private enum CodingKeys: String, CodingKey {
            case resolution, sessions, count, strengthMin, selectedHrIDs, rejectedEntries, gaps
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            // Keep JournalRow.revision on its Int64 encoder; the JSON diagnostic enum stores Double.
            try c.encode(resolution, forKey: .resolution)
            try c.encode(sessions, forKey: .sessions)
            try c.encode(count, forKey: .count)
            try c.encode(strengthMin, forKey: .strengthMin)
            try c.encode(selectedHrIDs, forKey: .selectedHrIDs)
            try c.encode(rejectedEntries, forKey: .rejectedEntries)
            try c.encode(gaps, forKey: .gaps)
        }
    }

    static func parse(_ row: C.JournalRow) throws -> Entry {
        let p = row.payload
        try V.keys(p, required: "schemaVersion timezone originalStart originalSport start end sport dismissed energyKcal distanceM steps consent")
        guard row.kind == .manualWorkout, !row.deleted, p["schemaVersion"] == .number(1),
              row.entity.hasPrefix("workout:"), let id = UUID(uuidString: String(row.entity.dropFirst(8))),
              "workout:" + id.uuidString.lowercased() == row.entity else { throw M.failure("manual_workout_identity") }
        _ = try C.dayBounds(row.effectiveDay, V.string(p["timezone"]))
        try M.consent(p["consent"], purpose: "manual_workouts")
        func timestamp(_ key: String) throws -> Int {
            let n = try V.number(p[key])
            guard let value = Int(exactly: n), (1...7_289_654_400).contains(value) else { throw M.failure("workout_timestamp") }
            return value
        }
        func scalar(_ key: String) throws -> Double? {
            if p[key] == .null { return nil }
            let n = try V.number(p[key])
            guard n.isFinite, (0...1_000_000).contains(n), key != "steps" || n.rounded(.towardZero) == n else {
                throw M.failure("workout_measurement")
            }
            return n
        }
        let start = try timestamp("start"), end = try timestamp("end"), original = try timestamp("originalStart")
        let sport = try V.string(p["sport"]), originalSport = try V.string(p["originalSport"])
        guard end > start, end - start <= 172_800, (1...128).contains(sport.count),
              (1...128).contains(originalSport.count), case .bool(let dismissed) = p["dismissed"] else {
            throw M.failure("workout_bounds_or_sport")
        }
        return try Entry(entity: row.entity, originalStart: original, originalSport: originalSport,
            start: start, end: end, sport: sport, dismissed: dismissed, manual: true, legacySource: nil,
            energyKcal: scalar("energyKcal"), distanceM: scalar("distanceM"), steps: scalar("steps").map(Int.init), inputRevision: row.revision)
    }

    static func resolve(scope: M.Scope, rows: [C.JournalRow], legacy: [Legacy]) throws -> Resolution {
        try scope.validate()
        guard rows.count <= 10_000, legacy.count <= 512 else { throw M.failure("workout_input_limit") }
        let selected = try C.resolve(C.Input(identity: scope.identity, day: scope.day, timezone: scope.timezone, journal: rows))
        let eligible = rows.filter { $0.kind == .manualWorkout && $0.userId == scope.identity.userId &&
            $0.sourceDeviceId == scope.identity.sourceDeviceId && $0.effectiveDay <= scope.day }
        for revisions in Dictionary(grouping: eligible, by: \.entity).values {
            var anchor: Entry?
            for row in revisions.sorted(by: { $0.revision < $1.revision }) where !row.deleted {
                let value = try parse(row)
                if let anchor, anchor.originalStart != value.originalStart || anchor.originalSport != value.originalSport {
                    throw M.failure("workout_anchor_changed")
                }
                if anchor == nil { anchor = value }
            }
        }
        let manual = try selected.rows.filter { $0.kind == .manualWorkout && !$0.deleted }
            .sorted { $0.revision > $1.revision }.map(parse)
        let lo = try C.dayBounds(scope.day, scope.timezone).lowerBound - 30 * 3_600
        let own = legacy.filter { $0.owner == scope.identity.userId && $0.device == scope.identity.sourceDeviceId &&
            !$0.algorithmIsServerOwned && !["server", "server_scoring", "frwhoop_scoring_v2"].contains($0.source) &&
            $0.start >= lo && $0.end <= scope.asOfExclusive }
        guard Set(own.map(\.id)).count == own.count else { throw M.failure("legacy_workout_duplicate_id") }
        let ordered = own.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
        let parsed = try ordered.map { row -> Entry in
            guard row.start > 0, row.end > row.start, !row.source.isEmpty else { throw M.failure("legacy_workout_bounds") }
            func measured(_ value: Double?, max: Double) -> Double? {
                value.flatMap { $0.isFinite && (0...max).contains($0) ? $0 : nil }
            }
            let sport = (1...128).contains(row.sport.count) ? row.sport : "Activity"
            return Entry(entity: "workout:" + row.id.uuidString.lowercased(), originalStart: row.start, originalSport: sport,
                start: row.start, end: row.end, sport: sport, dismissed: false,
                manual: row.userModified || row.source.lowercased().contains("manual"), legacySource: row.source,
                energyKcal: measured(row.energyKcal, max: 100_000), distanceM: measured(row.distanceM, max: 10_000_000),
                steps: row.steps.flatMap { (0...1_000_000).contains($0) ? $0 : nil }, inputRevision: nil)
        }
        return Resolution(scope: scope, originalRows: rows, originalLegacy: legacy, manual: manual, legacy: parsed,
            retainedTombstones: selected.rows.filter { $0.kind == .manualWorkout && $0.deleted })
    }

    struct Evaluation {
        let output: Output
        let detectionFunnel: C.JSON
    }

    static func evaluate(resolved: Resolution, raw: S.Loaded, cycleRaw: Cycle.Loaded, native: AnalyticsEngine.DayResult,
                         cycle: Cycle.CycleEvidence, profile: UserProfile, presentation: Presentation) throws -> Evaluation {
        let scope = resolved.scope, input = cycle.input
        guard scope.identity == input.identity, scope.day == input.day, scope.timezone == input.timezone,
              scope.asOfExclusive == input.asOfExclusive, raw.evidence.bounds == (try V.validate(input)),
              native.daily.day == input.day, cycleRaw.selected == cycle.selected,
              cycleRaw.predecessor == cycle.predecessor,
              cycleRaw.rejectedStepIDs == cycle.rejectedStepIDs else { throw M.failure("workout_execution_scope") }
        let zones = try presentation.zones(age: profile.age)
        let lo = cycle.window.startInclusive, hi = cycle.window.endExclusive, ownsDay = cycle.appliesToDay
        let future = resolved.manual.filter { !$0.dismissed && $0.start >= lo && $0.start < hi && $0.end > scope.asOfExclusive }
        let journal = resolved.manual.filter { ownsDay && !$0.dismissed && $0.start >= lo && $0.start < hi && $0.end <= scope.asOfExclusive }
        let legacy = resolved.legacy.filter { entry in
            ownsDay && entry.start >= lo && entry.start < hi && !resolved.manual.contains {
                $0.entity == entry.entity || ($0.originalStart == entry.start && $0.originalSport == entry.sport)
            }
        }
        let visible = journal + legacy
        var occupied: [Range<Int>] = [], sessions: [(Int, String, C.JSON)] = [], rejected: [String] = [], gaps: Set<String> = []
        var hrIDs: [String: [String]] = [:], strength = 0.0
        if ownsDay && !future.isEmpty { gaps.insert("manual_workout_ends_after_asof_cutoff") }
        func observedHR(_ start: Int, _ end: Int) -> [HRSample] {
            cycleRaw.hr.filter { $0.ts >= start && $0.ts < end && (20...250).contains($0.bpm) }
        }
        func finish(_ start: Int, _ end: Int, _ sport: String, _ id: String, fields: inout [String: C.JSON]) throws {
            let hr = observedHR(start, end)
            let onFoot = ["running", "walking", "hiking", "treadmill run", "treadmill walk"].contains(sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            let steps = cycleRaw.steps.filter { $0.ts >= start && $0.ts <= min(end, input.asOfExclusive - 1) }
            let ticks = onFoot ? StepsCounter.stepsInWindow(steps) : nil
            let scale = max(profile.stepTicksPerStep, 0.5)
            let scaled = ticks.map { Int((Double($0) / scale).rounded()) }.flatMap { $0 > 0 ? $0 : nil }
            fields["strapSteps"] = M.integer(scaled); fields["stepCounterTicks"] = M.integer(ticks)
            fields["strapStepsMethod"] = .string("session_inclusive_activity_class_counter")
            fields["stepTicksPerStep"] = onFoot ? M.number(scale) : .null
            let recovery = HeartRateRecovery.calculate(samples: cycleRaw.hr.filter { $0.ts < input.asOfExclusive },
                workoutStart: start, workoutEnd: end, maxHR: zones.maxHR)
            fields["heartRateRecovery"] = recovery.map { .object(["endHr": M.integer($0.endHR),
                "after1Minute": M.integer($0.after1Minute), "after2Minutes": M.integer($0.after2Minutes),
                "after5Minutes": M.integer($0.after5Minutes), "unit": .string("bpm_drop")]) } ?? .null
            fields["hrBuckets"] = try V.json(M.buckets(hr.map { ($0.ts, Double($0.bpm)) }, from: start, to: end, seconds: 60))
            fields["displayZoneSeconds"] = try hr.isEmpty ? .null : P.reflect(HRZones.timeInZone(hr, zoneSet: zones).seconds)
            fields["displayZoneSource"] = .string(zones.source)
            fields["displayZoneLowerBounds"] = try P.reflect(zones.zones.map(\.lower))
            hrIDs[id] = cycleRaw.selected["hr", default: []].filter { row in
                row.ts >= start && row.ts < end && ((try? V.number(row.fields["bpm"])) .map { (20...250).contains($0) } ?? false)
            }.map(\.id)
        }
        let method: StrainScorer.Method = raw.evidence.effectiveConfig["effortMethod"] == .string("BANISTER") ? .banister : .edwards
        for entry in visible {
            guard !occupied.contains(where: { $0.lowerBound < entry.end && entry.start < $0.upperBound }) else {
                rejected.append(entry.entity); gaps.insert("overlapping_workouts_explicit_journal_then_latest_upload_wins"); continue
            }
            occupied.append(entry.start..<entry.end)
            let hr = observedHR(entry.start, entry.end)
            let maxHR = presentation.maxHR ?? StrainScorer.estimateHRmax(hr.map { Double($0.bpm) }, age: profile.age).0
            let rhr = native.daily.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
            let energy = entry.energyKcal ?? (hr.isEmpty ? nil : Calories.estimateBoutCalories(hr, profile: profile, hrmax: maxHR, restingHR: rhr).0)
            if hr.isEmpty { gaps.insert(entry.legacySource == nil ? "manual_workout_raw_physiology_unavailable" : "uploaded_workout_raw_physiology_unavailable") }
            if entry.sport.lowercased().contains("strength") || entry.sport.lowercased().contains("weight") {
                strength += Double(entry.end - entry.start) / 60
            }
            let id = String(entry.entity.dropFirst(8))
            var fields: [String: C.JSON] = ["id": .string(id), "editEntity": .string(entry.entity),
                "originalStart": M.integer(entry.originalStart), "originalSport": .string(entry.originalSport),
                "start": M.integer(entry.start), "end": M.integer(entry.end), "sport": .string(entry.sport), "manual": .bool(entry.manual),
                "inputKind": .string(entry.legacySource == nil ? "manual_workout_journal" : "legacy_uploaded_workout"),
                "inputSource": .string(entry.legacySource ?? "user_entered"), "durationS": M.integer(entry.end - entry.start),
                "avgHr": M.number(DailyPresentationMath.mean(hr.map { Double($0.bpm) })), "peakHr": M.integer(hr.map(\.bpm).max()),
                "strain": M.number(StrainScorer.strain(hr, maxHR: maxHR, restingHR: rhr, method: method, sex: profile.sex)),
                "energyKcal": M.number(energy), "energyMethod": .string(entry.energyKcal == nil ? "hr_estimate" : entry.legacySource.map { "imported:" + $0 } ?? "user_entered"),
                "distanceM": M.number(entry.distanceM), "steps": M.integer(entry.steps),
                "hrCoveragePct": M.number(hr.isEmpty ? nil : WorkoutDetector.hrCoveragePct(sampleTs: hr.map(\.ts), start: entry.start, end: entry.end)),
                "zoneSeconds": try hr.isEmpty ? .null : P.reflect(HRZones.timeInZone(hr, zoneSet: zones).seconds), "zoneMethod": .string("hrmax_display_zones")]
            try finish(entry.start, entry.end, entry.sport, id, fields: &fields)
            sessions.append((entry.start, id, .object(fields)))
        }
        var detectionFunnel: WorkoutDetector.DetectionFunnel?
        let effectiveMaxHR = try C.number(raw.evidence.effectiveConfig, "maxHR") ??
            (profile.age > 0 ? StrainScorer.tanakaHRmax(age: profile.age) : nil)
        let automatic = ownsDay ? WorkoutDetector.detect(hr: cycleRaw.hr, gravity: cycleRaw.gravity,
            restingHR: native.daily.restingHr.map(Double.init), maxHR: effectiveMaxHR,
            age: profile.age > 0 ? profile.age : nil, profile: profile, effortMethod: method,
            funnel: { detectionFunnel = $0 }) : []
        for workout in automatic {
            guard ownsDay, workout.start >= lo, workout.start < hi, workout.end <= scope.asOfExclusive,
                  !resolved.manual.contains(where: { $0.originalStart == workout.start }),
                  !occupied.contains(where: { $0.lowerBound < workout.end && workout.start < $0.upperBound }) else { continue }
            let id = detectedID(scope, workout.start)
            var fields: [String: C.JSON] = ["id": .string(id), "start": M.integer(workout.start), "end": M.integer(workout.end),
                "durationS": M.number(workout.durationS), "sport": .string("Activity"), "manual": .bool(false),
                "avgHr": M.number(workout.avgHR), "peakHr": M.integer(workout.peakHR), "strain": M.number(workout.strain),
                "energyKcal": M.number(workout.caloriesKcal), "energyKJ": M.number(workout.caloriesKJ), "energyMethod": .string("hr_estimate"),
                "zoneTimePct": try P.reflect(workout.zoneTimePct), "zoneMethod": .string("edwards_hrr_samples"),
                "avgHrrPct": M.number(workout.avgHRRPct), "hrmax": M.number(workout.hrmax), "hrmaxSource": .string(workout.hrmaxSource),
                "hrCoveragePct": M.number(workout.hrCoveragePct)]
            try finish(workout.start, workout.end, "Activity", id, fields: &fields)
            sessions.append((workout.start, id, .object(fields)))
        }
        let known = ownsDay && (cycleRaw.hr.contains { $0.ts >= lo && $0.ts < hi } || !visible.isEmpty)
        let output = Output(resolution: resolved, sessions: sessions.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2),
            count: known ? sessions.count : nil, strengthMin: visible.isEmpty ? nil : strength,
            selectedHrIDs: hrIDs, rejectedEntries: rejected, gaps: gaps.sorted())
        return Evaluation(output: output, detectionFunnel: try P.reflect(detectionFunnel as Any))
    }

    static func detectedID(_ scope: M.Scope, _ start: Int) -> String {
        let key = "workout-v1|\(scope.identity.userId.uuidString.lowercased())|\(scope.identity.sourceDeviceId.uuidString.lowercased())|\(start)"
        var bytes = Array(Insecure.MD5.hash(data: Data(key.utf8)))
        bytes[6] = (bytes[6] & 0x0f) | 0x30; bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }
        return [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]].map { $0.joined() }.joined(separator: "-")
    }
}
