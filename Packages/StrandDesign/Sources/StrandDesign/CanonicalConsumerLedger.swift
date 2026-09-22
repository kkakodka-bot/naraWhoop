import Foundation

/// Immutable provenance shared by the phone's glance publishers and their widget/watch readers.
/// These are server receipts, not a second scoring model. An unavailable receipt has no invented revision.
public struct CanonicalConsumerLedger: Codable, Equatable, Hashable, Sendable {
    public struct Receipt: Codable, Equatable, Hashable, Sendable {
        public let family: String
        public let status: String
        public let reason: String?
        public let algorithmVersion: String?
        public let configurationVersion: String?
        public let modelVersion: String?
        public let preprocessingVersion: String?
        public let qualityVersion: String?
        public let inputRevision: Int64?
        public let resultRevision: String?
        public let computedAt: String?
        public let observedThrough: String?
        public let expiresAt: String?
        public let freshness: String
        public let timezoneID: String?
        public let manifestHash: String?
        public let featureManifestHash: String?
        public let canonicalAuthorization: String?

        public var permitsValue: Bool { permitsValue(at: Date()) }

        public func permitsValue(at now: Date) -> Bool {
            guard ["available", "stale"].contains(status), ["current", "stale"].contains(freshness),
                  Self.revision(resultRevision),
                  let inputRevision, inputRevision >= 0, Self.timestamp(computedAt) != nil,
                  algorithmVersion?.isEmpty == false, Self.hash(manifestHash) else { return false }
            if let expiresAt {
                guard let expiry = Self.timestamp(expiresAt), expiry > now else { return false }
            }
            return algorithmVersion == "frwhoop-server-1" && canonicalAuthorization == "retained_legacy" ||
                canonicalAuthorization == "signed_reference_approval" && Self.hash(featureManifestHash)
        }

        private static func hash(_ value: String?) -> Bool {
            guard let value, value.count == 64 else { return false }
            return value.allSatisfy { "0123456789abcdef".contains($0) }
        }
        fileprivate static func revision(_ value: String?) -> Bool {
            guard let value else { return false }
            if value.hasPrefix("sha256:") { return hash(String(value.dropFirst(7))) }
            for prefix in ["compute:", "session:"] where value.hasPrefix(prefix) {
                let suffix = value.dropFirst(prefix.count)
                return !suffix.isEmpty && suffix.allSatisfy { "0123456789".contains($0) }
            }
            return false
        }
        fileprivate static func timestamp(_ value: String?) -> Date? {
            guard let value else { return nil }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: value)
        }

        public init(family: String, status: String, reason: String?, algorithmVersion: String?,
                    configurationVersion: String?, modelVersion: String?, preprocessingVersion: String?,
                    qualityVersion: String?, inputRevision: Int64?, resultRevision: String?,
                    computedAt: String?, observedThrough: String?, freshness: String, timezoneID: String?,
                    manifestHash: String?, featureManifestHash: String?, canonicalAuthorization: String?, expiresAt: String? = nil) {
            self.family = family; self.status = status; self.reason = reason
            self.algorithmVersion = algorithmVersion; self.configurationVersion = configurationVersion
            self.modelVersion = modelVersion; self.preprocessingVersion = preprocessingVersion
            self.qualityVersion = qualityVersion; self.inputRevision = inputRevision
            self.resultRevision = resultRevision; self.computedAt = computedAt
            self.observedThrough = observedThrough; self.freshness = freshness; self.timezoneID = timezoneID
            self.expiresAt = expiresAt
            self.manifestHash = manifestHash; self.featureManifestHash = featureManifestHash
            self.canonicalAuthorization = canonicalAuthorization
        }
    }
    public let project: String
    public let ownerID: String
    public let sourceID: String
    public let deviceID: String
    public let window: String
    public let families: [String: Receipt]
    /// Transport state is separate from the immutable physiological result revision.
    public let readState: String?
    public let cached: Bool?

    public init(project: String, ownerID: String, sourceID: String, deviceID: String,
                window: String, families: [String: Receipt], readState: String? = nil, cached: Bool? = nil) {
        self.project = project; self.ownerID = ownerID; self.sourceID = sourceID
        self.deviceID = deviceID; self.window = window; self.families = families
        self.readState = readState; self.cached = cached
    }

    public var permitsRead: Bool {
        !["failed", "offline", "authenticationRequired", "timezoneMismatch", "unsupported"].contains(readState ?? "")
    }

    public var scopeIdentity: String { [project, ownerID, sourceID, deviceID].joined(separator: "|") }
    public var isValid: Bool {
        guard URL(string: project)?.host != nil, UUID(uuidString: ownerID) != nil,
              UUID(uuidString: sourceID) != nil, UUID(uuidString: deviceID) != nil,
              !window.isEmpty, !families.isEmpty else { return false }
        return families.allSatisfy { key, receipt in
            key == receipt.family && ["current", "stale", "expired", "unavailable"].contains(receipt.freshness) &&
                (receipt.inputRevision == nil || receipt.inputRevision! >= 0) &&
                [receipt.computedAt, receipt.observedThrough, receipt.expiresAt].allSatisfy({ $0 == nil || Receipt.timestamp($0) != nil }) &&
                (receipt.resultRevision == nil || (Receipt.revision(receipt.resultRevision) &&
                    receipt.inputRevision != nil && receipt.algorithmVersion?.isEmpty == false && receipt.computedAt != nil))
        }
    }
}
