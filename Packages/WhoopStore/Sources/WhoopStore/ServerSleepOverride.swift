import Foundation

public struct ServerSleepOverride: Equatable, Identifiable {
    public let id: String, deviceId: String
    public let originalStart: Int, originalEnd: Int, start: Int, end: Int
    public let tombstone: Bool
    public let revision: Int64
    public let legacyRevision: String?
    public let originalStartAt: String?, originalEndAt: String?
}

/// Immutable edit identity and original opportunity survive every successive correction.
public struct ServerSleepEditTarget: Equatable, Identifiable {
    public let id: String, ownerId: String, deviceId: String, day: String
    public let originalStart: Int, originalEnd: Int, start: Int, end: Int
    public let expectedRevision: Int64
    public let legacyRevision: String?
    public let originalStartAt: String?, originalEndAt: String?
    public var rpcName: String {
        legacyRevision == nil ? "set_physiology_sleep_override" : "continue_legacy_physiology_sleep_override"
    }
    public enum EditError: Error { case unavailable, missingRevision, invalidBounds }

    public static func prepare(cache: ServerScoreDayCache, nightId: String,
                               newId: String = UUID().uuidString.lowercased()) throws -> Self {
        guard !cache.ownerId.isEmpty, cache.features["sleep"]?.supportsBoundaryOverrides == true,
              let night = cache.nights.first(where: { $0.id == nightId }),
              let device = night.deviceId, device == cache.features["sleep"]?.deviceId,
              let start = epoch(night.startAt), let end = epoch(night.endAt), end > start else { throw EditError.unavailable }
        let provenanceId = night.boundaryProvenance?.hasPrefix("user_boundary:") == true
            ? night.boundaryProvenance?.components(separatedBy: ":").last : nil
        if let provenanceId, UUID(uuidString: provenanceId) != nil {
            guard let prior = cache.sleepOverrides.first(where: {
                $0.deviceId == device && $0.id.caseInsensitiveCompare(provenanceId) == .orderedSame
            }) else { throw EditError.missingRevision }
            return try prepare(cache: cache, existing: prior)
        }
        let prior = cache.sleepOverrides.first {
            $0.deviceId == device && (($0.start == start && $0.end == end) ||
                ($0.originalStart == start && $0.originalEnd == end))
        }
        if let prior { return try prepare(cache: cache, existing: prior) }
        guard UUID(uuidString: newId) != nil else { throw EditError.unavailable }
        return Self(id: newId, ownerId: cache.ownerId, deviceId: device, day: cache.day,
                    originalStart: start, originalEnd: end, start: start, end: end, expectedRevision: 0,
                    legacyRevision: nil, originalStartAt: nil, originalEndAt: nil)
    }

    public static func prepare(cache: ServerScoreDayCache, existing: ServerSleepOverride) throws -> Self {
        guard !cache.ownerId.isEmpty, cache.features["sleep"]?.supportsBoundaryOverrides == true,
              cache.features["sleep"]?.deviceId == existing.deviceId,
              UUID(uuidString: existing.id) != nil,
              existing.revision > 0 || (existing.revision == 0 && validLegacyToken(existing.legacyRevision)) else {
            throw EditError.unavailable
        }
        return Self(id: existing.id, ownerId: cache.ownerId, deviceId: existing.deviceId, day: cache.day,
                    originalStart: existing.originalStart, originalEnd: existing.originalEnd,
                    start: existing.start, end: existing.end, expectedRevision: existing.revision,
                    legacyRevision: existing.legacyRevision, originalStartAt: existing.originalStartAt,
                    originalEndAt: existing.originalEndAt)
    }

    public func rpcArguments(start: Int, end: Int, tombstone: Bool) throws -> [String: Any] {
        guard end > start, end - start <= 48 * 3600, originalEnd > originalStart,
              originalEnd - originalStart <= 48 * 3600 else { throw EditError.invalidBounds }
        let iso = ISO8601DateFormatter()
        func date(_ ts: Int) -> String { iso.string(from: Date(timeIntervalSince1970: Double(ts))) }
        var arguments: [String: Any] = ["p_id": id, "p_device": deviceId,
                "p_original_start": originalStartAt ?? date(originalStart),
                "p_original_end": originalEndAt ?? date(originalEnd), "p_start": date(start), "p_end": date(end),
                "p_tombstone": tombstone, "p_expected_revision": expectedRevision]
        if let legacyRevision { arguments["p_legacy_revision"] = legacyRevision }
        return arguments
    }

    fileprivate static func validLegacyToken(_ token: String?) -> Bool {
        guard let token else { return false }
        return token.count == 64 && token.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func epoch(_ value: String) -> Int? {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: value) { return Int(date.timeIntervalSince1970) }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: value).map { Int($0.timeIntervalSince1970) }
    }
}

public extension ServerScoreDayCache {
    var sleepOverrides: [ServerSleepOverride] {
        guard let data = rawSnapshotJSON?.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let overlay = root["server_scoring"] as? [String: Any],
              let rows = overlay["sleep_overrides"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let device = row["device_id"] as? String,
                  device == features["sleep"]?.deviceId,
                  let originalStart = row["original_start"] as? Int, let originalEnd = row["original_end"] as? Int,
                  let start = row["start"] as? Int, let end = row["end"] as? Int,
                  let tombstone = row["tombstone"] as? Bool, let revision = row["revision"] as? NSNumber,
                  originalEnd > originalStart, end > start else { return nil }
            let token = row["legacy_revision"] as? String
            let legacy = row["source"] as? String == "legacy_user_boundary"
            guard (legacy && revision.int64Value == 0 && ServerSleepEditTarget.validLegacyToken(token)) ||
                    (!legacy && revision.int64Value > 0 && token == nil) else { return nil }
            return ServerSleepOverride(id: id, deviceId: device, originalStart: originalStart, originalEnd: originalEnd,
                                       start: start, end: end, tombstone: tombstone, revision: revision.int64Value,
                                       legacyRevision: token, originalStartAt: row["original_start_at"] as? String,
                                       originalEndAt: row["original_end_at"] as? String)
        }
    }
}
