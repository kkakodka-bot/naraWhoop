import Foundation
import CryptoKit
import GRDB
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

enum WholeDaySwiftParityExporter {
    static let user = "11111111-1111-4111-8111-111111111111"
    static let device = "22222222-2222-4222-8222-222222222222"
    static let otherUser = "33333333-3333-4333-8333-333333333333"
    static let otherDevice = "44444444-4444-4444-8444-444444444444"
    static let foreignDevice = "55555555-5555-4555-8555-555555555555"
    static let streams = ["hr", "rr", "resp", "gravity", "events", "steps", "skinTemp", "spo2", "bandState", "ppgHr"]
    static let fields: [String: [String]] = [
        "hr": ["ts", "bpm"], "rr": ["ts", "rrMs", "seq", "ord", "srcChannel", "tsSuspect"],
        "resp": ["ts", "raw"], "gravity": ["ts", "x", "y", "z"], "events": ["ts", "kind", "payloadJSON"],
        "steps": ["ts", "counter", "activityClass", "provenance"],
        "skinTemp": ["ts", "raw", "aux1Raw", "aux2Raw"], "spo2": ["ts", "red", "ir"],
        "bandState": ["ts", "state", "rawByte", "provenance"], "ppgHr": ["ts", "bpm", "conf", "provenance"]
    ]
    static let tables = ["hr": "hrSample", "rr": "rrInterval", "resp": "respSample", "gravity": "gravitySample",
                         "events": "event", "steps": "stepSample", "skinTemp": "skinTempSample", "spo2": "spo2Sample",
                         "bandState": "sleepStateSample", "ppgHr": "ppgHrSample"]
    static func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
    static func bytes(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    struct Recipe {
        let id: String
        var family = "whoop5"
        var day = "2026-06-15"
        var timezone = "UTC"
        var stagerV2 = false
        var deepOnly = false
        var raw = Dictionary(uniqueKeysWithValues: streams.map { ($0, [[String: Any]]()) })

        mutating func append(_ stream: String, _ values: [String: Any], userId: String = user, deviceId: String = device) {
            var row: [String: Any] = ["id": "\(stream)-\(raw[stream]!.count + 1)", "userId": userId, "deviceId": deviceId]
            for field in fields[stream]! { row[field] = values[field] ?? NSNull() }
            raw[stream]!.append(row)
        }

        func bounds() throws -> [String: Int] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: day), let zone = TimeZone(identifier: timezone) else {
                throw Failure.invalidRecipe
            }
            // kernel_calendar deliberately uses the unchanged engine's single captured offset.
            let offset = zone.secondsFromGMT(for: date)
            let lo = Int(date.timeIntervalSince1970) - offset
            return ["dayLo": lo, "dayHi": lo + 86_399, "nightLo": lo - 30 * 3_600,
                    "nightHi": lo + 86_399, "tzOffsetSeconds": offset]
        }
    }

    enum Failure: Error { case invalidRecipe, identityNotUnique, unsafeOutput, nonFiniteResult }

    static func firstRecipes() throws -> [Recipe] {
        var result = [Recipe(id: "empty-utc")]
        var legacy = Recipe(id: "whoop4-legacy-boundaries", family: "whoop4")
        let b = try legacy.bounds(), lo = b["dayLo"]!, hi = b["nightHi"]!, night = b["nightLo"]!
        let edges = [night - 1, night, night + 1, lo - 1, lo, lo + 1, hi - 1, hi, hi + 1]
        for (i, ts) in edges.enumerated() {
            legacy.append("hr", ["ts": ts, "bpm": 65 + i])
            legacy.append("rr", ["ts": ts, "rrMs": 850 + i, "seq": 0])
            legacy.append("steps", ["ts": ts, "counter": i * 10])
            legacy.append("gravity", ["ts": ts, "x": 0.0, "y": 0.0, "z": 1.0])
            legacy.append("resp", ["ts": ts, "raw": 140 + i])
            legacy.append("skinTemp", ["ts": ts, "raw": 826])
            legacy.append("spo2", ["ts": ts, "red": 1000 + i, "ir": 1200 + i])
            legacy.append("bandState", ["ts": ts, "state": 0, "rawByte": 0])
        }
        legacy.append("rr", ["ts": lo + 50, "rrMs": 910, "seq": 0, "srcChannel": 2])
        legacy.append("rr", ["ts": lo + 50, "rrMs": 911, "seq": 0, "tsSuspect": 1])
        legacy.append("events", ["ts": lo + 20, "kind": "WRIST_OFF(10)", "payloadJSON": "{}"])
        legacy.append("events", ["ts": lo + 40, "kind": "WRIST_ON(11)", "payloadJSON": "{}"])
        legacy.append("hr", ["ts": lo + 80, "bpm": 199], deviceId: otherDevice)
        legacy.append("rr", ["ts": lo + 80, "rrMs": 500, "seq": 0], userId: otherUser, deviceId: foreignDevice)
        result.append(legacy)

        var channels = Recipe(id: "whoop5-channel5-order-exclusions")
        channels.append("rr", ["ts": lo + 100, "rrMs": 800, "seq": 0, "ord": 1, "srcChannel": 5])
        channels.append("rr", ["ts": lo + 100, "rrMs": 800, "seq": 1, "ord": 0, "srcChannel": 5])
        channels.append("rr", ["ts": lo + 100, "rrMs": 801, "seq": 0, "ord": 2, "srcChannel": 7])
        channels.append("rr", ["ts": lo + 100, "rrMs": 802, "seq": 0, "srcChannel": 110])
        channels.append("rr", ["ts": lo + 100, "rrMs": 803, "seq": 0])
        channels.append("rr", ["ts": lo + 101, "rrMs": 804, "seq": 0, "srcChannel": 5, "tsSuspect": 1])
        channels.append("rr", ["ts": lo + 102, "rrMs": 805, "seq": 0, "srcChannel": 6])
        channels.append("rr", ["ts": hi + 1, "rrMs": 806, "seq": 0, "srcChannel": 5])
        channels.append("rr", ["ts": lo + 100, "rrMs": 700, "seq": 0, "srcChannel": 5], deviceId: otherDevice)
        channels.append("rr", ["ts": lo + 100, "rrMs": 701, "seq": 0, "srcChannel": 5], userId: otherUser, deviceId: foreignDevice)
        result.append(channels)

        var fallback = Recipe(id: "whoop5-channel7-suspect5-future5")
        fallback.append("rr", ["ts": lo + 100, "rrMs": 820, "seq": 0, "ord": 0, "srcChannel": 7])
        fallback.append("rr", ["ts": lo + 100, "rrMs": 830, "seq": 0, "ord": 1, "srcChannel": 7])
        fallback.append("rr", ["ts": lo + 100, "rrMs": 840, "seq": 0, "srcChannel": 5, "tsSuspect": 1])
        fallback.append("rr", ["ts": hi + 1, "rrMs": 850, "seq": 0, "srcChannel": 5])
        result.append(fallback)

        var hrOnly = Recipe(id: "whoop5-hr-only-night")
        for offset in stride(from: -16 * 3_600, to: 8 * 3_600, by: 10) {
            let asleep = offset >= 0
            let wave = Int(sin(Double(offset) / (asleep ? 900.0 : 500.0)) * (asleep ? 5.0 : 11.0))
            let bpm = (asleep ? 64 : 74) + wave
            hrOnly.append("hr", ["ts": lo + offset, "bpm": bpm])
            hrOnly.append("rr", ["ts": lo + offset, "rrMs": 60_000 / bpm, "seq": 0, "ord": 0, "srcChannel": 5])
        }
        result.append(hrOnly)
        return result
    }

    private static func dbValue(_ value: Any) throws -> DatabaseValue {
        if value is NSNull { return .null }
        if let value = value as? Int { return value.databaseValue }
        if let value = value as? Double { return value.databaseValue }
        if let value = value as? String { return value.databaseValue }
        return String(decoding: try bytes(value), as: UTF8.self).databaseValue
    }

    static func seed(_ recipe: Recipe) async throws -> WhoopStore {
        var stores: [String: WhoopStore] = [:]
        let owners = Set([user] + recipe.raw.values.flatMap { $0.compactMap { $0["userId"] as? String } })
        for owner in owners {
            let store = try await WhoopStore.inMemory()
            try await store.bindAccountOwner(projectURL: "https://parity-fixture.invalid", userID: owner)
            let deviceIDs = Set([device] + recipe.raw.values.flatMap { rows in rows.filter { $0["userId"] as? String == owner }
                .compactMap { $0["deviceId"] as? String } })
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            for id in deviceIDs {
                try registry.add(PairedDevice(id: id, brand: "WHOOP", model: recipe.family == "whoop4" ? "WHOOP 4.0" : "WHOOP 5.0",
                    sourceKind: .historyBLE, capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
            }
            try await store.registryWriter.write { db in
                for stream in streams {
                    let columns = fields[stream]!.map { $0 == "provenance" ? "provenanceJSON" : $0 }
                    for (index, row) in recipe.raw[stream]!.enumerated() where row["userId"] as? String == owner {
                        let values = [(index + 1) as Any, row["deviceId"]!] + fields[stream]!.map { row[$0]! }
                        let sql = "INSERT INTO \(tables[stream]!)(rowid,deviceId,\(columns.joined(separator: ","))) VALUES (\(Array(repeating: "?", count: values.count).joined(separator: ",")))"
                        try db.execute(sql: sql, arguments: StatementArguments(try values.map(dbValue)))
                    }
                }
            }
            stores[owner] = store
        }
        return stores[user]!
    }

    static func export(_ recipe: Recipe) async throws -> [String: Any] {
        let b = try recipe.bounds(), lo = b["dayLo"]!, hi = b["dayHi"]!, night = b["nightLo"]!
        let store = try await seed(recipe), limit = 200_000
        let hr = try await store.hrSamples(deviceId: device, from: night, to: hi, limit: limit)
        let rr = try await store.rrIntervals(deviceId: device, from: night, to: hi, limit: limit)
        let resp = try await store.respSamples(deviceId: device, from: night, to: hi, limit: limit)
        let gravity = try await store.gravitySamples(deviceId: device, from: night, to: hi, limit: limit)
        let steps = try await store.stepSamples(deviceId: device, from: night, to: hi, limit: limit)
        let skin = try await store.skinTempSamples(deviceId: device, from: night, to: hi, limit: limit)
        let spo2 = try await store.spo2Samples(deviceId: device, from: night, to: hi, limit: limit)
        let events = try await store.events(deviceId: device, from: night, to: hi, limit: limit)
        let band = try await store.sleepStateSamples(deviceId: device, from: night, to: hi)
        let ppg = try await store.ppgHrSamples(deviceId: device, from: night, to: hi)
        let dayHr = try await store.hrSamples(deviceId: device, from: lo, to: hi, limit: limit)
        let daySteps = try await store.stepSamples(deviceId: device, from: lo, to: hi, limit: limit)
        let dayGravity = try await store.gravitySamples(deviceId: device, from: lo, to: hi, limit: limit)
        let off = AnalyticsEngine.offWristIntervals(events: events, windowEnd: hi)
        let profile = UserProfile()
        let provided = gravity.isEmpty ? SleepStager.hrOnlySessions(hr: hr, rr: rr, resp: resp) : []
        let result = AnalyticsEngine.analyzeDay(day: recipe.day, hr: hr, rr: rr, resp: resp, gravity: gravity,
            steps: steps, dayHr: dayHr, daySteps: daySteps, dayGravity: dayGravity, skinTemp: skin,
            skinTempFamily: recipe.family == "whoop4" ? .whoop4 : .whoop5, spo2: spo2, profile: profile,
            tzOffsetSeconds: b["tzOffsetSeconds"]!, wristOff: off, bandSleepState: band.map { ($0.ts, $0.state) },
            useSleepStagerV2: recipe.stagerV2, useMotionAwareWake: false, providedSleep: provided,
            deepHrvWindow: recipe.deepOnly, effortMethod: .edwards)

        func ids(_ stream: String, _ timestamps: [Int]) throws -> [String] {
            let rows = recipe.raw[stream]!.filter { $0["userId"] as? String == user && $0["deviceId"] as? String == device }
            let grouped = Dictionary(grouping: rows) { $0["ts"] as! Int }
            return try timestamps.map { ts in
                guard let matches = grouped[ts], matches.count == 1 else { throw Failure.identityNotUnique }
                return matches[0]["id"] as! String
            }
        }
        // Resolve identities from the actual returned Store rows, not a copied RR selection predicate.
        let rrIDs = try await store.registryWriter.read { db in
            try rr.map { sample -> String in
                guard let rowid = try Int.fetchOne(db, sql: "SELECT rowid FROM rrInterval WHERE deviceId=? AND ts=? AND rrMs=? AND seq=?",
                    arguments: [device, sample.ts, sample.rrMs, sample.seq]) else { throw Failure.identityNotUnique }
                return recipe.raw["rr"]![rowid - 1]["id"] as! String
            }
        }
        let eventIDs = try events.map { event -> String in
            let matches = recipe.raw["events"]!.filter { $0["userId"] as? String == user && $0["deviceId"] as? String == device &&
                $0["ts"] as? Int == event.ts && $0["kind"] as? String == event.kind }
            guard matches.count == 1 else { throw Failure.identityNotUnique }
            return matches[0]["id"] as! String
        }
        let selected: [String: Any] = ["hr": try ids("hr", hr.map(\.ts)), "rr": rrIDs,
            "resp": try ids("resp", resp.map(\.ts)), "gravity": try ids("gravity", gravity.map(\.ts)),
            "events": eventIDs, "steps": try ids("steps", steps.map(\.ts)), "skinTemp": try ids("skinTemp", skin.map(\.ts)),
            "spo2": try ids("spo2", spo2.map(\.ts)), "bandState": try ids("bandState", band.map(\.ts)),
            "ppgHr": try ids("ppgHr", ppg.map(\.ts))]
        let sessions = result.sleepSessions
        let main = SleepStageTotals.mainNightGroupIndices(sessions.map { .init(start: $0.start, end: $0.end) },
            offsetSec: b["tzOffsetSeconds"]!) ?? []
        let motionSessions = sessions.indices.filter { !sessions[$0].hrOnly }
        let physiology = motionSessions.isEmpty ? Array(sessions.indices) : motionSessions
        let windows = sessions.flatMap { session in
            SleepStager.sessionHrvWindows(start: session.start, end: session.end, rr: rr.sortedByTsStable(), stages: session.stages)
                .map { ["sessionStart": session.start, "start": $0.startTs, "stage": $0.stage,
                        "cleanBeats": $0.cleanBeats, "rmssd": optional($0.rmssd)] as [String: Any] }
        }
        let selection: [String: Any] = ["bounds": b, "streams": selected,
            "dayHr": try ids("hr", dayHr.map(\.ts)), "daySteps": try ids("steps", daySteps.map(\.ts)),
            "dayGravity": try ids("gravity", dayGravity.map(\.ts)), "vendorResp": [String](),
            "scoringResp": try ids("resp", resp.map(\.ts)), "wristOff": off.map { ["start": $0.start, "end": $0.end] },
            "profileRevision": 1, "configurationRevision": 2, "sleepEditEntities": [String](),
            "mainNightIndices": main, "physiologySessionIndices": physiology, "hrvWindows": windows]
        let profileJSON: [String: Any] = ["age": profile.age, "sex": profile.sex, "weightKg": profile.weightKg,
            "heightCm": profile.heightCm, "waistCm": NSNull(), "stepTicksPerStep": profile.stepTicksPerStep]
        let config: [String: Any] = ["schemaVersion": 1, "useSleepStagerV2": recipe.stagerV2, "useMotionAwareWake": false,
            "deepHrvWindow": recipe.deepOnly, "effortMethod": "EDWARDS", "dayCycleMode": "midnight"]
        var profilePayload = profileJSON
        profilePayload["schemaVersion"] = 1; profilePayload["timezone"] = recipe.timezone
        let journal: [[String: Any]] = [
            ["kind": "profile", "entity": "primary", "revision": 1, "effectiveDay": recipe.day, "deleted": false, "payload": profilePayload],
            ["kind": "config", "entity": "primary", "revision": 2, "effectiveDay": recipe.day, "deleted": false, "payload": config]
        ]
        return ["schemaVersion": 1, "id": recipe.id, "mode": "kernel_calendar",
            "input": ["userId": user, "deviceId": device, "externalDeviceId": device, "deviceFamily": recipe.family,
                "day": recipe.day, "timezone": recipe.timezone, "profile": profileJSON, "config": config,
                "bounds": b, "raw": recipe.raw, "history": [String](), "journal": journal],
            "expected": ["selection": selection, "result": try encode(result)]]
    }

    static func encode(_ r: AnalyticsEngine.DayResult) throws -> [String: Any] {
        var daily = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r.daily)) as! [String: Any]
        for key in "totalSleepMin efficiency deepMin remMin lightMin disturbances restingHr avgHrv recovery strain exerciseCount spo2Pct skinTempDevC respRateBpm steps activeKcalEst spo2Red spo2Ir avgSdnn skinTempC sleepHrOnly".split(separator: " ") {
            if daily[String(key)] == nil { daily[String(key)] = NSNull() }
        }
        daily["deviceId"] = device // WhoopStore's writer attaches device identity; DailyMetric itself has no such member.
        let sleep: [[String: Any]] = r.sleepSessions.map {
            ["start": $0.start, "end": $0.end, "efficiency": $0.efficiency, "restingHR": optional($0.restingHR),
             "avgHRV": optional($0.avgHRV), "hrOnly": $0.hrOnly,
             "stages": $0.stages.map { ["start": $0.start, "end": $0.end, "stage": $0.stage] as [String: Any] }]
        }
        let workouts: [[String: Any]] = r.workouts.map {
            ["start": $0.start, "end": $0.end, "avgHR": $0.avgHR, "peakHR": $0.peakHR, "strain": optional($0.strain),
             "durationS": $0.durationS, "zoneTimePct": Dictionary(uniqueKeysWithValues: $0.zoneTimePct.map { (String($0.key), $0.value) }),
             "avgHRRPct": optional($0.avgHRRPct), "hrmax": optional($0.hrmax), "hrmaxSource": $0.hrmaxSource,
             "caloriesKcal": optional($0.caloriesKcal), "caloriesKJ": optional($0.caloriesKJ), "hrCoveragePct": optional($0.hrCoveragePct)]
        }
        let funnel: Any = r.detectionFunnel.map { f -> Any in
            ["hrSamples": f.hrSamples, "motionSamples": f.motionSamples, "restingHR": optional(f.restingHR),
             "hrFloor": optional(f.hrFloor), "motionPassed": f.motionPassed, "hrMissing": f.hrMissing, "hrTooLow": f.hrTooLow,
             "active": f.active, "runs": f.runs, "bridged": f.bridged, "longestRunS": f.longestRunS, "meanRunS": f.meanRunS,
             "droppedShort": f.droppedShort, "droppedNoHR": f.droppedNoHR, "droppedLowIntensity": f.droppedLowIntensity, "kept": f.kept]
        } ?? NSNull()
        return ["daily": daily, "sleep": sleep, "workouts": workouts,
            "scores": ["recovery": optional(r.recovery), "strain": optional(r.strain), "rest": optional(r.restScore),
                "nightlySkinTempC": optional(r.nightlySkinTempC), "chargeConfidence": r.chargeConfidence.rawValue,
                "effortConfidence": r.effortConfidence.rawValue, "restConfidence": r.restConfidence.rawValue],
            "sessionMotionByStart": Dictionary(uniqueKeysWithValues: r.sessionMotionByStart.map { (String($0.key), $0.value) }),
            "sessionSleepStateByStart": Dictionary(uniqueKeysWithValues: r.sessionSleepStateByStart.map { (String($0.key), $0.value) }),
            "detectionFunnel": funnel]
    }
}
