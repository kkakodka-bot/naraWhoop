import Foundation

/// A server receipt before a canonical device exists. It is deliberately not a
/// ServerCanonicalResults or a device ownership ledger, and cannot contain values.
public struct ServerPendingCanonicalResults: Codable, Equatable, Sendable {
    private let wire: [String: ServerJSONValue]

    public var project: String { string("project") }
    public var ownerID: String { string("owner_id") }
    public var sourceID: String { string("source_id") }
    public var day: String { string("day") }
    public var reason: String { "device_registration_pending" }
    public var familyIDs: Set<String> { Set(families.keys) }
    public var ownedMetrics: Set<String> { ServerCanonicalResults.allMetrics }

    private func string(_ key: String) -> String {
        if case .string(let value) = wire[key] { return value }
        return ""
    }
    private var families: [String: ServerJSONValue] {
        if case .object(let value) = wire["families"] { return value }
        return [:]
    }
    public init(from decoder: Decoder) throws {
        wire = try decoder.singleValueContainer().decode([String: ServerJSONValue].self)
        try validate(owner: ownerID, day: day)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wire)
    }

    public func validate(owner: String, day: String, project expectedProject: String? = nil,
                         source: String? = nil) throws {
        guard string("mode") == "final_hosted", string("policy_version") == "vps-only-1",
              ownerID == owner.lowercased(), self.day == day,
              UUID(uuidString: ownerID) != nil, UUID(uuidString: sourceID) != nil,
              let url = URLComponents(string: project), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(url.host!),
              expectedProject == nil || ServerCanonicalResults.projectKey(project) == ServerCanonicalResults.projectKey(expectedProject!),
              source == nil || sourceID == source, wire["device_id"] == .null,
              familyIDs == Set(ServerCanonicalResults.familyMetrics.keys)
        else { throw ServerScoreCacheCodec.DecodeError.invalidScope }
        for (key, value) in families {
            guard case .object(let family) = value,
                  case .array(let metrics) = family["metrics"],
                  Set(metrics.compactMap { if case .string(let text) = $0 { return text }; return nil }) == ServerCanonicalResults.familyMetrics[key],
                  metrics.count == ServerCanonicalResults.familyMetrics[key]?.count,
                  family["owner"] == .string("server"), family["owner_id"] == .string(ownerID),
                  family["project"] == .string(project), family["source_id"] == .string(sourceID),
                  family["device_id"] == .null, family["window"] == .string(day),
                  family["status"] == .string("unavailable"), family["reason"] == .string(reason),
                  family["result_revision"] == .null, family["input_revision"] == .null,
                  family["computed_at"] == .null, family["observed_through"] == .null,
                  family["manifest_hash"] == .null, family["feature_manifest_hash"] == .null,
                  family["canonical_qualification"] == .null, family["timezone_id"] == .null,
                  family["freshness"] == .string("unavailable"), family["details"] == .object([:]),
                  case .object(let values) = family["values"],
                  Set(values.keys) == ServerCanonicalResults.familyMetrics[key],
                  values.values.allSatisfy({ $0 == .null })
            else { throw ServerScoreCacheCodec.DecodeError.invalidPayload }
        }
    }
}
