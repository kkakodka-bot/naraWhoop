import Foundation
import StrandDesign

/// Synthetic authorization receipts for testing the shared glance cache contract.
/// These are not production qualification or independently measured sensor evidence.
enum CanonicalGlanceFixture {
    static let ownerA = "10000000-0000-4000-8000-000000000001"
    static let ownerB = "10000000-0000-4000-8000-000000000002"

    static func ledger(owner: String = ownerA, revision: String = "compute:7",
                       recoveryStatus: String = "available") -> CanonicalConsumerLedger {
        let families = ["recovery", "strain_energy", "sleep_history", "sleep", "night_hrv"]
        return CanonicalConsumerLedger(project: "https://fixture.example", ownerID: owner,
            sourceID: "20000000-0000-4000-8000-000000000001",
            deviceID: "30000000-0000-4000-8000-000000000001", window: "2023-11-14",
            families: Dictionary(uniqueKeysWithValues: families.map { family in
                (family, .init(family: family,
                    status: family == "recovery" ? recoveryStatus : "available", reason: nil,
                    algorithmVersion: "fixture-signed-v1", configurationVersion: "fixture-config-v1",
                    modelVersion: nil, preprocessingVersion: nil, qualityVersion: "fixture-quality-v1",
                    inputRevision: 3, resultRevision: revision,
                    computedAt: "2023-11-14T22:13:20Z", observedThrough: "2023-11-14T22:00:00Z",
                    freshness: "current", timezoneID: "UTC", manifestHash: String(repeating: "a", count: 64),
                    featureManifestHash: String(repeating: "b", count: 64),
                    canonicalAuthorization: "signed_reference_approval"))
            }))
    }
}
