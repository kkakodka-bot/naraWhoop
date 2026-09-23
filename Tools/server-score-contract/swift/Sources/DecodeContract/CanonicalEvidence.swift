import Foundation
import WhoopStore

private func changedCache(_ cache: ServerScoreDayCache,
                          _ change: (inout [String: Any]) -> Void) throws -> ServerScoreDayCache {
    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as! [String: Any]
    change(&object)
    return try JSONDecoder().decode(ServerScoreDayCache.self,
        from: JSONSerialization.data(withJSONObject: object))
}

private func changedFamily(_ cache: ServerScoreDayCache, key: String,
                           _ change: (inout [String: Any]) -> Void) throws -> ServerScoreDayCache {
    try changedCache(cache) { object in
        var contract = object["canonicalResults"] as! [String: Any]
        var families = contract["families"] as! [String: Any]
        var family = families[key] as! [String: Any]
        change(&family)
        families[key] = family; contract["families"] = families; object["canonicalResults"] = contract
    }
}

func verifyCanonicalSelection(_ cache: ServerScoreDayCache, bytes: Data,
                              expectation: Expectation, directory: URL) throws {
    let file = expectation.file
    let target = directory.appendingPathComponent("swift-persisted", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let cacheFile = target.appendingPathComponent(file)
    try JSONEncoder().encode(cache).write(to: cacheFile, options: .atomic)
    let restored = try JSONDecoder().decode(ServerScoreDayCache.self, from: Data(contentsOf: cacheFile))
    try require(restored == cache, "\(file): production cache changed after disk reload")
    try require(ServerComputeRevisionFence.admits(previous: cache, next: restored), "\(file): identical revision rejected")

    if let pending = restored.pendingCanonicalResults {
        try require(restored.canonicalResults == nil && pending.familyIDs.count == 27 &&
            restored.ownedMetrics == ServerCanonicalResults.allMetrics,
            "\(file): pending registration lost server ownership after disk reload")
        return
    }
    guard let results = restored.canonicalResults else { throw ContractFailure(description: "\(file): missing final canonical contract") }
    try results.validate(owner: expectation.ownerId, day: expectation.day, device: expectation.expectedDeviceId)
    try require(results.families.count == 27, "\(file): incomplete canonical ownership")

    let suite = "noop.compute.decoder.contract.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let scope = ServerMetricOwnership.Scope(project: results.project, ownerID: results.ownerID, deviceID: results.deviceID)
    let observed = ServerMetricOwnershipStore(defaults: defaults).observe(restored, scope: scope)
    try require(observed.metrics == ServerCanonicalResults.allMetrics, "\(file): production ledger did not observe every family")
    defaults.synchronize()
    let ledger = ServerMetricOwnershipStore(defaults: UserDefaults(suiteName: suite)!).load(scope)
    try require(ledger == observed, "\(file): production ownership ledger changed after reload")
    guard let selected = ledger.presentation(restored, day: expectation.day), let selectedResults = selected.canonicalResults else {
        throw ContractFailure(description: "\(file): persisted ledger lost canonical selection")
    }
    try require(selectedResults == results && selected.ownedMetrics == ServerCanonicalResults.allMetrics,
                "\(file): consumer selection changed result identities")
    let empty = ledger.presentation(nil, day: "1900-01-01", readFailed: true)
    try require(empty?.ownedMetrics == ServerCanonicalResults.allMetrics && empty?.canonicalResults == nil &&
        empty?.readFailure == "server_read_failed", "\(file): empty/read-failed day lost explicit server ownership")
    for other in [ServerMetricOwnership.Scope(project: "https://other.invalid", ownerID: results.ownerID, deviceID: results.deviceID),
                  .init(project: results.project, ownerID: UUID().uuidString, deviceID: results.deviceID),
                  .init(project: results.project, ownerID: results.ownerID, deviceID: UUID().uuidString)] {
        try require(ServerMetricOwnershipStore(defaults: defaults).load(other).metrics.isEmpty,
                    "\(file): persisted ownership crossed project/account/device")
    }

    let response = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
    let raw = (response["server_scoring"] as! [String: Any])["compute"] as! [String: Any]
    let rawFamilies = raw["families"] as! [String: [String: Any]]
    for (key, family) in selectedResults.families {
        let decodedRaw = try JSONDecoder().decode(ServerCanonicalFamilyResult.self,
            from: JSONSerialization.data(withJSONObject: rawFamilies[key]!))
        try require(family == decodedRaw, "\(file): \(key) identity/evidence/value changed after persistence")
        for metric in family.metrics {
            let expected = ["available", "stale"].contains(family.status) && family.hasCanonicalAuthorization && !family.isExpired()
                ? decodedRaw.values[metric]?.number : nil
            try require(family.number(metric) == expected, "\(file): canonical \(metric) selection differs")
        }
    }
    let aliases = ["sleep": "sleep_total_min", "hrv": "hrv_rmssd_ms", "respiration": "resp_rate_bpm"]
    for (key, expected) in expectation.expectedValues ?? [:] {
        let metric = aliases[key]!
        try require(selectedResults.result(for: metric)?.number(metric) == expected,
                    "\(file): final canonical \(metric) differs from SQL fixture expectation")
    }
    for (metric, expected) in expectation.expectedCanonicalValues ?? [:] {
        try require(selectedResults.result(for: metric)?.number(metric) == expected,
                    "\(file): final canonical \(metric) unit/value differs")
    }
    for key in expectation.unavailableFeatures {
        let metric = aliases[key]!
        try require(selectedResults.result(for: metric)?.number(metric) == nil,
                    "\(file): unauthorized canonical \(metric) was selected")
    }
    let restricted = (expectation.nestedHrvAvailable ? [] : ["hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm", "overnight_hr_bpm",
        "hrv_summary", "heart_rate_windows", "recovery", "strain", "spo2_pct", "skin_temp_c", "skin_temp_dev_c"]) +
        (expectation.nestedRespirationAvailable ? [] : ["resp_rate_bpm", "respiration_summary"])
    let sleep = rawFamilies["sleep"]!
    let nested = ((sleep["details"] as? [String: Any])?["nights"] as? [[String: Any]] ?? []) +
        ((sleep["values"] as? [String: Any])?["sleep_sessions"] as? [[String: Any]] ?? [])
    for night in nested { for field in restricted where !(expectation.allowedNestedFields ?? []).contains(field) {
        try require(night[field] == nil || night[field] is NSNull, "\(file): canonical sleep leaked \(field)")
    } }

    for (key, value) in [("project", "https://other.invalid"), ("owner_id", UUID().uuidString.lowercased()),
                         ("source_id", UUID().uuidString.lowercased()), ("device_id", UUID().uuidString.lowercased()),
                         ("day", "1900-01-01")] {
        let other = try changedCache(restored) { object in
            var contract = object["canonicalResults"] as! [String: Any]
            contract[key] = value
            var families = contract["families"] as! [String: [String: Any]]
            for family in families.keys { families[family]![key == "day" ? "window" : key] = value }
            contract["families"] = families; object["canonicalResults"] = contract
            if key == "owner_id" { object["ownerId"] = value }
            if key == "day" { object["day"] = value }
        }
        try require(!ServerComputeRevisionFence.admits(previous: restored, next: other), "\(file): revision fence crossed \(key)")
    }
    for (key, family) in results.families where ["available", "stale"].contains(family.status) {
        guard let metric = family.metrics.first(where: { family.number($0) != nil }), let value = family.number(metric) else { continue }
        let changed = try changedFamily(restored, key: key) { result in
            var values = result["values"] as! [String: Any]; values[metric] = value + 1; result["values"] = values
        }
        try require(!ServerComputeRevisionFence.admits(previous: restored, next: changed), "\(file): immutable \(key) values mutated")
        if let input = family.inputRevision, input > 0 {
            let older = try changedFamily(restored, key: key) { $0["input_revision"] = input - 1 }
            try require(!ServerComputeRevisionFence.admits(previous: restored, next: older), "\(file): older input revision admitted")
        }
        let revoked = try changedFamily(restored, key: key) { result in
            result["status"] = "revoked"; result["reason"] = "qualification_revoked"
            result["values"] = Dictionary(uniqueKeysWithValues: family.metrics.map { ($0, NSNull()) })
        }
        try require(ServerComputeRevisionFence.admits(previous: restored, next: revoked) &&
            revoked.canonicalResults?.families[key]?.resultRevision == family.resultRevision &&
            revoked.canonicalResults?.families[key]?.number(metric) == nil,
            "\(file): same-identity revocation did not clear canonical value")
    }
}
