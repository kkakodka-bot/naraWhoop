import Foundation
import NoopPush

/// Effective-day content is distinct from the optimistic entity head, which may be scheduled later.
struct ScoringInputValue: Sendable, Equatable {
    let head: ScoringInputHead
    let revision: Int64?
    let effectiveDay: String?
    let deleted: Bool?
    let payload: Data?

    private struct Metadata: Decodable {
        let schemaVersion: Int
        let userId: UUID
        let sourceDeviceId: UUID
        let kind: ScoringInputChange.Kind
        let entity: String
        let headRevision: Int64
        let revision: Int64?
        let effectiveDay: String?
        let deleted: Bool?
    }

    init(data: Data, scope: AccountScope, change: ScoringInputChange, asOfDay: String) throws {
        guard data.count <= 72 * 1024, ServerScoreDate.isDay(asOfDay),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              ["revision", "effectiveDay", "deleted", "payload"].allSatisfy({ object[$0] != nil }) else {
            throw ScoringInputRPC.Failure.invalidResponse
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        head = .init(schemaVersion: metadata.schemaVersion, userId: metadata.userId,
                     sourceDeviceId: metadata.sourceDeviceId, kind: metadata.kind,
                     entity: metadata.entity, headRevision: metadata.headRevision)
        guard head.matches(scope: scope, change: change) else { throw ScoringInputRPC.Failure.invalidResponse }
        revision = metadata.revision; effectiveDay = metadata.effectiveDay; deleted = metadata.deleted
        if let revision {
            guard revision > 0, revision <= head.headRevision, let effectiveDay,
                  ServerScoreDate.isDay(effectiveDay), effectiveDay <= asOfDay,
                  let deleted else { throw ScoringInputRPC.Failure.invalidResponse }
            if deleted {
                guard object["payload"] is NSNull else { throw ScoringInputRPC.Failure.invalidResponse }
                payload = nil
            } else {
                guard let body = object["payload"] as? [String: Any] else { throw ScoringInputRPC.Failure.invalidResponse }
                let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                guard encoded.count <= 65536 else { throw ScoringInputRPC.Failure.invalidResponse }
                payload = encoded
            }
        } else {
            guard effectiveDay == nil, deleted == nil, object["payload"] is NSNull else {
                throw ScoringInputRPC.Failure.invalidResponse
            }
            payload = nil
        }
    }
}
