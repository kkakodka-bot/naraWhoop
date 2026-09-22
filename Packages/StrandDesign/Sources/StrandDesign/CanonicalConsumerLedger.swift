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
        public let freshness: String
        public let timezoneID: String?
        public let manifestHash: String?
        public let featureManifestHash: String?
        public let canonicalAuthorization: String?

        public var permitsValue: Bool {
            guard ["available", "stale"].contains(status), resultRevision?.isEmpty == false,
                  let inputRevision, inputRevision >= 0, computedAt != nil else { return false }
            if algorithmVersion == "frwhoop-server-1" { return true }
            func hash(_ value: String?) -> Bool {
                guard let value, value.count == 64 else { return false }
                return value.allSatisfy { "0123456789abcdef".contains($0) }
            }
            return canonicalAuthorization == "signed_reference_approval" && hash(manifestHash) && hash(featureManifestHash)
        }

        public init(family: String, status: String, reason: String?, algorithmVersion: String?,
                    configurationVersion: String?, modelVersion: String?, preprocessingVersion: String?,
                    qualityVersion: String?, inputRevision: Int64?, resultRevision: String?,
                    computedAt: String?, observedThrough: String?, freshness: String, timezoneID: String?,
                    manifestHash: String?, featureManifestHash: String?, canonicalAuthorization: String?) {
            self.family = family; self.status = status; self.reason = reason
            self.algorithmVersion = algorithmVersion; self.configurationVersion = configurationVersion
            self.modelVersion = modelVersion; self.preprocessingVersion = preprocessingVersion
            self.qualityVersion = qualityVersion; self.inputRevision = inputRevision
            self.resultRevision = resultRevision; self.computedAt = computedAt
            self.observedThrough = observedThrough; self.freshness = freshness; self.timezoneID = timezoneID
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
            key == receipt.family && (receipt.resultRevision == nil ||
                (receipt.inputRevision != nil && receipt.algorithmVersion != nil && receipt.computedAt != nil))
        }
    }
}
