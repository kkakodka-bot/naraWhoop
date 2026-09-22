import Foundation

/// Read-time availability may change, but a published physiological value cannot change under
/// the same immutable identity. Revocation always wins over a previously authorized cache.
public enum ServerComputeRevisionFence {
    public static func admits(previous: ServerScoreDayCache?, next: ServerScoreDayCache) -> Bool {
        guard let before = previous?.canonicalResults else { return true }
        guard let after = next.canonicalResults,
              before.project == after.project, before.ownerID == after.ownerID,
              before.sourceID == after.sourceID, before.deviceID == after.deviceID,
              before.day == after.day else { return false }
        return before.families.allSatisfy { key, old in
            guard let fresh = after.families[key], old.window == fresh.window else { return false }
            // An unavailable/revoked response must clear the old numeric publication immediately.
            guard ["available", "stale"].contains(fresh.status) else { return true }
            if old.algorithmVersion == fresh.algorithmVersion,
               let oldInput = old.inputRevision, let newInput = fresh.inputRevision, newInput < oldInput { return false }
            guard old.resultRevision != nil, old.resultRevision == fresh.resultRevision,
                  ["available", "stale"].contains(old.status) else { return true }
            return immutable(old) == immutable(fresh)
        }
    }
    private static func immutable(_ value: ServerCanonicalFamilyResult) -> Data? {
        guard let data = try? JSONEncoder().encode(value),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["freshness", "status", "reason"] { object.removeValue(forKey: key) }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
