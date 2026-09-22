import Foundation
import GRDB
import WhoopProtocol
import WhoopStore
@testable import StrandAnalytics

enum ServerDaySwiftV3Selection {
    typealias V = ServerDaySwiftV3Contract
    typealias C = ServerDaySwiftContract

    static let tables: [C.Stream: String] = [.hr: "hrSample", .rr: "rrInterval", .resp: "respSample",
        .gravity: "gravitySample", .events: "event", .steps: "stepSample", .skinTemp: "skinTempSample",
        .spo2: "spo2Sample", .bandState: "sleepStateSample", .ppgHr: "ppgHrSample"]
    static let modernFamilies: Set<String> = ["whoop5", "whoop5_mg", "whoopmg", "whoop 5.0", "5.0", "mg"]
    static let legacyFamilies: Set<String> = ["whoop4", "whoop 4.0", "4.0"]

    struct Seed {
        let stores: [UUID: WhoopStore]
        let rows: [Int64: C.RawRow]
        let input: V.Input
        var store: WhoopStore { stores[input.identity.userId]! }
    }

    struct Loaded {
        let evidence: V.Selection
        let hr: [HRSample]
        let rr: [RRInterval]
        let resp: [RespSample]
        let gravity: [GravitySample]
        let steps: [StepSample]
        let skinTemp: [SkinTempSample]
        let spo2: [SpO2Sample]
        let events: [WhoopEvent]
        let bandState: [SleepStateSample]
        let ppgHr: [PpgHrSample]
    }

    static func seed(_ input: V.Input) async throws -> Seed {
        try V.validate(input)
        if let family = input.source.registryFamily?.lowercased() {
            let expected: DeviceFamily? = modernFamilies.contains(family) ? .whoop5 : legacyFamilies.contains(family) ? .whoop4 : nil
            if let expected {
                guard DeviceFamily.confirmedRegistryFamily(model: input.source.storeModel, brand: input.source.storeBrand) == expected else {
                    throw V.failure("known_family_registry_conflict")
                }
            }
        }
        let indexed = Dictionary(uniqueKeysWithValues: input.raw.enumerated().map { (Int64($0.offset + 1), $0.element) })
        var stores: [UUID: WhoopStore] = [:]
        let owners = Set(input.raw.map(\.userId)).union([input.identity.userId])
        for owner in owners.sorted(by: { $0.uuidString < $1.uuidString }) {
            let store = try await WhoopStore.inMemory()
            try await store.bindAccountOwner(projectURL: "https://s10-synthetic.invalid", userID: owner.uuidString.lowercased())
            let ownRows = indexed.filter { $0.value.userId == owner }
            let devices = Set(ownRows.values.map(\.sourceDeviceId)).union(owner == input.identity.userId ? [input.identity.sourceDeviceId] : [])
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            for device in devices.sorted(by: { $0.uuidString < $1.uuidString }) {
                try registry.add(PairedDevice(id: device.uuidString.lowercased(), brand: input.source.storeBrand,
                    model: input.source.storeModel, sourceKind: .historyBLE, capabilities: [.hr], status: .paired,
                    addedAt: 1, lastSeenAt: 1))
            }
            try await store.registryWriter.write { db in
                for (rowid, row) in ownRows.sorted(by: { $0.key < $1.key }) {
                    let shape = V.fields[row.stream]!
                    let fields = shape.required.union(shape.optional).sorted()
                    let columns = fields.map { $0 == "provenance" ? "provenanceJSON" : $0 }
                    let values: [DatabaseValue] = [rowid.databaseValue, row.sourceDeviceId.uuidString.lowercased().databaseValue,
                        row.ts.databaseValue] + (try fields.map { try databaseValue(row.fields[$0] ?? .null) })
                    try db.execute(sql: "INSERT INTO \(tables[row.stream]!)(rowid,deviceId,ts,\(columns.joined(separator: ","))) VALUES (\(Array(repeating: "?", count: values.count).joined(separator: ",")))",
                        arguments: StatementArguments(values))
                }
            }
            stores[owner] = store
        }
        return Seed(stores: stores, rows: indexed, input: input)
    }

    private static func databaseValue(_ json: C.JSON) throws -> DatabaseValue {
        switch json {
        case .null: return .null
        case .number(let n): return Int64(exactly: n)?.databaseValue ?? n.databaseValue
        case .string(let s): return s.databaseValue
        case .bool(let b): return b.databaseValue
        default: return String(decoding: try C.bytes(json), as: UTF8.self).databaseValue
        }
    }

    static func load(_ seed: Seed) async throws -> Loaded {
        let input = seed.input, store = seed.store
        let b = try V.validate(input), resolution = try C.resolve(input.historyInput)
        let device = input.identity.sourceDeviceId.uuidString.lowercased()
        var rows: [C.Stream: [Row]] = [:]
        for stream in C.Stream.allCases {
            let table = tables[stream]!
            let ordering = stream == .rr ? "ts, ord, rrMs, seq" : stream == .events ? "ts, kind" : "ts"
            rows[stream] = try await store.registryWriter.read { db in
                try Row.fetchAll(db, sql: "SELECT rowid AS fixtureRowId,* FROM \(table) WHERE deviceId=? AND ts BETWEEN ? AND ? ORDER BY \(ordering)",
                    arguments: [device, b.nightLo, b.nightHi])
            }
        }
        let eligibleRR = rows[.rr]!.filter { row in
            let suspect: Int? = row["tsSuspect"], channel: Int? = row["srcChannel"]
            return suspect != 1 && channel != RRSourceChannel.spo2Ibi.rawValue
        }
        let channels = eligibleRR.compactMap { $0["srcChannel"] as Int? }
        let modern = channels.contains { [5, 6, 7].contains($0) }
        let canonical = channels.filter { [5, 7].contains($0) }.min()
        let family = input.source.registryFamily?.lowercased()
        let strict = family.map(modernFamilies.contains) ?? modern
        let serverRR = eligibleRR.filter { !strict || (canonical != nil && ($0["srcChannel"] as Int?) == canonical) }
        let shippedStrict = try await store.isWhoop5RRSource(deviceId: device)
        let shipped = try await store.rrIntervals(deviceId: device, from: b.nightLo, to: b.nightHi, limit: V.rowLimit + 1)
        struct RRKey: Hashable { let ts: Int; let rrMs: Int; let seq: Int }
        let rrIndex = Dictionary(uniqueKeysWithValues: rows[.rr]!.map { (RRKey(ts: $0["ts"], rrMs: $0["rrMs"], seq: $0["seq"]), $0) })
        let shippedRows = try shipped.map { sample -> Row in
            guard let row = rrIndex[RRKey(ts: sample.ts, rrMs: sample.rrMs, seq: sample.seq)] else { throw V.failure("rr_identity") }
            return row
        }
        let knownFamily = family.map { modernFamilies.contains($0) || legacyFamilies.contains($0) } ?? false
        if knownFamily {
            guard try identities(serverRR, seed).map(\.id) == identities(shippedRows, seed).map(\.id) else {
                throw V.failure("known_family_store_disagreement")
            }
        }
        rows[.rr] = knownFamily ? shippedRows : serverRR

        let predecessor = try await store.registryWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT rowid AS fixtureRowId,* FROM stepSample WHERE deviceId=? AND ts<? ORDER BY ts DESC LIMIT 1",
                arguments: [device, b.nightLo])
        }
        if let predecessor { rows[.steps]!.insert(predecessor, at: 0) }
        var gaps: [String] = []
        func gap(_ value: String) { if !gaps.contains(value) { gaps.append(value) } }
        var provenance: [Int64: ScalarProvenance] = [:]
        for (stream, lane) in [(C.Stream.steps, "stepSample"), (.bandState, "sleepStateSample"), (.ppgHr, "ppgHrSample")] {
            rows[stream] = rows[stream]!.filter { row in
                let parsed: ScalarProvenance?
                do {
                    parsed = try ScalarProvenance.decodeJSON(row["provenanceJSON"] as String?)
                    if let end = parsed?.inputEndTs, end - 1 > b.nightHi { throw V.failure("future_provenance") }
                } catch { gap(lane + "_provenance_invalid"); return false }
                let valid: Bool
                switch stream {
                case .steps:
                    let count: Int = row["counter"], activity: Int? = row["activityClass"]
                    valid = (0...65_535).contains(count) && (activity.map { (0...2).contains($0) } ?? true)
                case .bandState:
                    let state: Int = row["state"], raw: Int? = row["rawByte"]
                    valid = (0...3).contains(state) && (raw.map { (0...255).contains($0) && ($0 >> 4 & 3) == state } ?? true)
                default:
                    let bpm: Int = row["bpm"], conf: Double = row["conf"]
                    valid = bpm > 0 && conf.isFinite && (0...1).contains(conf)
                }
                guard valid else { gap(lane + "_measurement_invalid"); return false }
                if let parsed { provenance[row["fixtureRowId"] as Int64] = parsed }
                else { gap(lane + "_provenance_unknown") }
                return true
            }
        }

        let hr = rows[.hr]!.map { HRSample(ts: $0["ts"], bpm: $0["bpm"]) }
        let rr = knownFamily ? shipped : rows[.rr]!.map {
            RRInterval(ts: $0["ts"], rrMs: $0["rrMs"], srcChannel: ($0["srcChannel"] as Int?).flatMap(RRSourceChannel.init(rawValue:)),
                ord: $0["ord"], seq: $0["seq"])
        }
        let resp = try await store.respSamples(deviceId: device, from: b.nightLo, to: b.nightHi, limit: V.rowLimit + 1)
        let gravity = try await store.gravitySamples(deviceId: device, from: b.nightLo, to: b.nightHi, limit: V.rowLimit + 1)
        let skin = try await store.skinTempSamples(deviceId: device, from: b.nightLo, to: b.nightHi, limit: V.rowLimit + 1)
        let spo2 = try await store.spo2Samples(deviceId: device, from: b.nightLo, to: b.nightHi, limit: V.rowLimit + 1)
        let events = try await store.events(deviceId: device, from: b.nightLo, to: b.nightHi, limit: V.rowLimit + 1)
        let steps = rows[.steps]!.map { StepSample(ts: $0["ts"], counter: $0["counter"], activityClass: $0["activityClass"],
            provenance: provenance[$0["fixtureRowId"] as Int64]) }
        let band = rows[.bandState]!.map { SleepStateSample(ts: $0["ts"], state: $0["state"], rawByte: $0["rawByte"],
            provenance: provenance[$0["fixtureRowId"] as Int64]) }
        let ppg = rows[.ppgHr]!.map { PpgHrSample(ts: $0["ts"], bpm: $0["bpm"], conf: $0["conf"],
            provenance: provenance[$0["fixtureRowId"] as Int64]) }

        var selected: [String: [V.StoredIdentity]] = [:]
        for stream in C.Stream.allCases { selected[stream.rawValue] = try identities(rows[stream]!, seed) }
        func dayIDs(_ stream: C.Stream) -> [String] { selected[stream.rawValue]!.filter { b.dayRange.contains($0.ts) }.map(\.id) }
        let validPredecessor = selected["steps"]!.first { $0.ts < b.nightLo }
        if validPredecessor != nil {
            let actual = try await store.stepSampleBefore(deviceId: device, before: b.nightLo)
            guard actual == steps.first else { throw V.failure("step_predecessor_store_disagreement") }
        }
        var retained: [String: [String: Int]] = [:]
        for (owner, accountStore) in seed.stores {
            var counts: [String: Int] = [:]
            for stream in C.Stream.allCases {
                counts[stream.rawValue] = try await accountStore.registryWriter.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(tables[stream]!)")!
                }
            }
            retained[owner.uuidString.lowercased()] = counts
        }
        let profile = resolution.payload(.profile)
        func n(_ key: String, _ fallback: Double) throws -> C.JSON { .number(try C.number(profile, key) ?? fallback) }
        let effectiveProfile: [String: C.JSON] = ["age": try n("age", 30), "weightKg": try n("weightKg", 70),
            "heightCm": try n("heightCm", 170), "sex": profile["sex"] == nil || profile["sex"] == .null ? .string("nonbinary") : profile["sex"]!,
            "waistCm": profile["waistCm"] ?? .null, "stepTicksPerStep": try n("stepTicksPerStep", 1)]
        let evidence = V.Selection(bounds: b, streams: selected, dayHr: dayIDs(.hr), daySteps: dayIDs(.steps), dayGravity: dayIDs(.gravity),
            vendorResp: [], scoringResp: selected["resp"]!.map(\.id), stepPredecessor: validPredecessor?.id,
            rrPolicy: V.RRPolicy(adapter: knownFamily ? "actual-store-known-family" : "server-window-unknown-family-v1",
                canonicalOnly: strict, canonicalChannel: canonical, windowHasModern: modern,
                shippedStoreCanonicalOnly: shippedStrict, shippedStoreIDs: try identities(shippedRows, seed).map(\.id),
                serverWindowIDs: try identities(serverRR, seed).map(\.id)), gaps: gaps, retainedByOwner: retained,
            profileRevision: resolution.head(.profile)?.revision ?? 0, configurationRevision: resolution.head(.config)?.revision ?? 0,
            effectiveProfile: effectiveProfile, effectiveConfig: resolution.payload(.config))
        return Loaded(evidence: evidence, hr: hr, rr: rr, resp: resp, gravity: gravity, steps: steps,
            skinTemp: skin, spo2: spo2, events: events, bandState: band, ppgHr: ppg)
    }

    private static func identities(_ rows: [Row], _ seed: Seed) throws -> [V.StoredIdentity] {
        try rows.map { row in
            let rowid: Int64 = row["fixtureRowId"]
            guard let original = seed.rows[rowid], original.userId == seed.input.identity.userId,
                  original.sourceDeviceId == seed.input.identity.sourceDeviceId, original.ts == row["ts"] as Int else {
                throw V.failure("selected_identity")
            }
            return V.StoredIdentity(id: original.id, rowid: rowid, ts: original.ts, fields: original.fields)
        }
    }
}
