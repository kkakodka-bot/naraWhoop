import Foundation

/// A rendering cutover survives empty days and failures. Qualification is checked again for
/// every value; retaining ownership never authorizes a previously revoked result.
public struct ServerMetricOwnership: Codable, Equatable, Sendable {
    public struct Scope: Codable, Equatable, Sendable {
        public let project: String
        public let ownerID: String
        public let deviceID: String

        public init(project: String, ownerID: String, deviceID: String) {
            self.project = project.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            self.ownerID = ownerID.lowercased()
            self.deviceID = deviceID
        }
    }

    public struct Claim: Codable, Equatable, Sendable {
        public let metrics: Set<String>
        public let algorithmVersion: String
        public let inputRevision: Int64
        public let manifestHash: String?
        public let featureManifestHash: String?
    }

    public let scope: Scope
    public private(set) var claims: [String: Claim] = [:]

    public init(scope: Scope) { self.scope = scope }

    // Only outputs actually serialized by the physiology read contract belong here. The
    // historical shadow contract's richer details cannot be inferred from these three features.
    public static let featureMetrics: [String: Set<String>] = [
        "hrv": ["hrv_rmssd_ms", "resting_hr_bpm", "recovery", "strain", "spo2_pct",
                "skin_temp_c", "skin_temp_dev_c"],
        "respiration": ["resp_rate_bpm"],
        "sleep": ["sleep_performance", "sleep_total_min", "sleep_in_bed_min", "sleep_awake_min",
                  "sleep_light_min", "sleep_deep_min", "sleep_rem_min", "sleep_efficiency", "sleep_sessions"],
    ]

    public var metrics: Set<String> {
        claims.values.reduce(into: Set<String>()) { $0.formUnion($1.metrics) }
    }

    @discardableResult
    public mutating func observe(_ cache: ServerScoreDayCache) -> Bool {
        guard cache.ownerId.lowercased() == scope.ownerID else { return false }
        let before = claims
        for (key, feature) in cache.features where Self.featureMetrics[key] != nil {
            guard feature.deviceId == scope.deviceID, feature.isCanonicalAvailable,
                  let version = feature.algorithmVersion, let revision = feature.inputRevision,
                  revision >= 0, feature.computedAt != nil else { continue }
            if let prior = claims[key], prior.algorithmVersion == version,
               prior.inputRevision > revision { continue }
            claims[key] = Claim(metrics: Self.featureMetrics[key] ?? [], algorithmVersion: version, inputRevision: revision,
                manifestHash: feature.manifestHash, featureManifestHash: feature.featureManifestHash)
        }
        return before != claims
    }

    public func owns(_ metric: String) -> Bool { metrics.contains(metric) }

    public func presentation(_ cache: ServerScoreDayCache?, day: String, readFailed: Bool = false) -> ServerScoreDayCache? {
        if var cache, cache.day == day, cache.ownerId.lowercased() == scope.ownerID,
           cache.features.values.allSatisfy({ $0.deviceId == nil || $0.deviceId == scope.deviceID }) {
            cache.ownedMetrics = metrics
            if readFailed { cache.stale = true; cache.readFailure = "server_read_failed" }
            return cache
        }
        guard !claims.isEmpty else { return nil }
        var pending = ServerScoreDayCache(day: day, algorithmVersion: "per_feature", daily: nil,
            nights: [], computedAt: nil, stale: false, fetchedAt: .distantPast)
        pending.ownerId = scope.ownerID
        pending.ownedMetrics = metrics
        pending.readFailure = readFailed ? "server_read_failed" : nil
        // This is a local presentation of an outstanding server read, never a cached publication.
        for (key, claim) in claims {
            pending.features[key] = ServerScoreFeatureCache(status: "pending", reason: "awaiting_server_result",
                deviceId: scope.deviceID, algorithmVersion: claim.algorithmVersion, inputRevision: nil,
                requiredRevision: nil, computedAt: nil, observedThrough: nil, publicationStatus: nil,
                archiveStatus: nil, manifestHash: nil)
        }
        return pending
    }

    /// A daily kernel also produces history, workouts, baselines and context. The narrow
    /// physiology response cannot prove that its complete replacement is consumed.
    public static let dailyKernelOutputs: Set<String> = [
        "hrv_rmssd_ms", "hrv_sdnn_ms", "resting_hr_bpm", "resp_rate_bpm", "recovery", "strain",
        "sleep_sessions", "sleep_total_min", "sleep_in_bed_min", "sleep_awake_min", "sleep_light_min",
        "sleep_deep_min", "sleep_rem_min", "sleep_efficiency", "sleep_performance", "disturbances",
        "steps", "active_kcal_est", "steps_est", "exercise_count", "workouts", "spo2_pct", "spo2_red",
        "spo2_ir", "skin_temp_c", "skin_temp_dev_c", "fitness_age", "vo2max_est", "vitality", "body_age",
        "sleep_need_min", "sleep_debt_min", "sleep_consistency", "historical_baselines",
    ]
    public var canRetireDailyKernel: Bool { Self.dailyKernelOutputs.isSubset(of: metrics) }
}

/// The scope is part of both the key and payload. A prior project's or wearable's cutover
/// cannot be inherited through a reused installation or the last day fetched.
public final class ServerMetricOwnershipStore {
    private let defaults: UserDefaults
    private static let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ scope: ServerMetricOwnership.Scope) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return "noop.compute.ownership.v1." + (try! encoder.encode(scope)).base64EncodedString()
    }

    private func read(_ scope: ServerMetricOwnership.Scope) -> ServerMetricOwnership {
        guard let data = defaults.data(forKey: key(scope)),
              let value = try? JSONDecoder().decode(ServerMetricOwnership.self, from: data),
              value.scope == scope,
              value.claims.allSatisfy({ key, claim in
                  claim.inputRevision >= 0 && !claim.algorithmVersion.isEmpty &&
                    claim.metrics.isSubset(of: ServerMetricOwnership.featureMetrics[key] ?? [])
              }) else { return .init(scope: scope) }
        return value
    }

    public func load(_ scope: ServerMetricOwnership.Scope) -> ServerMetricOwnership {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return read(scope)
    }

    public func observe(_ cache: ServerScoreDayCache, scope: ServerMetricOwnership.Scope) -> ServerMetricOwnership {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var value = read(scope)
        if value.observe(cache), let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key(scope))
        }
        return value
    }
}
