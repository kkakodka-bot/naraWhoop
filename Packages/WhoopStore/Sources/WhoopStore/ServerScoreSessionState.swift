import Foundation

/// In-memory account fence, shared by the repository and delayed-response regression tests.
public struct ServerScoreSessionState {
    public private(set) var ownerId: String?
    public private(set) var generation: UInt64 = 0
    private var values: [String: ServerScoreDayCache] = [:]
    private var requests: [String: UInt64] = [:]
    public init() {}
    public mutating func activate(ownerId: String?) {
        self.ownerId = ownerId?.lowercased()
        generation &+= 1
        values.removeAll()
        requests.removeAll()
    }
    public mutating func beginRequest(day: String) -> UInt64 {
        let next = (requests[day] ?? 0) &+ 1
        requests[day] = next
        return next
    }
    public func isCurrentRequest(day: String, generation: UInt64, currentOwnerId: String?, request: UInt64) -> Bool {
        generation == self.generation && ownerId != nil && currentOwnerId?.lowercased() == ownerId && requests[day] == request
    }
    public func overlay(day: String, currentOwnerId: String?) -> ServerScoreDayCache? {
        guard let ownerId, currentOwnerId?.lowercased() == ownerId else { return nil }
        return values[day]
    }
    @discardableResult public mutating func accept(_ value: ServerScoreDayCache, generation: UInt64,
                                                   currentOwnerId: String?, request: UInt64? = nil) -> Bool {
        guard generation == self.generation, let ownerId, currentOwnerId?.lowercased() == ownerId,
              value.ownerId == ownerId, value.schemaVersion == ServerScoreCacheCodec.schemaVersion,
              !value.features.isEmpty else { return false }
        if let request, requests[value.day] != request { return false }
        if let old = values[value.day], old.scopeKey == value.scopeKey {
            for (feature, prior) in old.features {
                if let priorRevision = prior.inputRevision, let newRevision = value.features[feature]?.inputRevision,
                   newRevision < priorRevision { return false }
            }
        }
        values[value.day] = value
        return true
    }
}
