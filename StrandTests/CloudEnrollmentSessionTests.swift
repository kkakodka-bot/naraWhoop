import Foundation
import NoopPush
import WhoopStore
import XCTest
@testable import Strand

final class CloudEnrollmentSessionTests: XCTestCase {
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let otherOwner = "99999999-9999-4999-8999-999999999999"
    private let source = "22222222-2222-4222-8222-222222222222"
    private func credential(owner: String? = nil, token: String = "noop_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ") -> CloudEnrollmentCredential {
        .init(userId: owner ?? self.owner, sourceId: source,
              tokenId: "33333333-3333-4333-8333-333333333333", uploadToken: token)
    }

    func testSuccessfulEnrollmentEnablesCloudAndPreservesNetworkPreference() throws {
        let name = "CloudEnrollmentSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "cloudPush.enabled")
        defaults.set(false, forKey: ServerScoringSettings.defaultsKey)
        defaults.set(false, forKey: "cloudPush.wifiOnly")
        CloudEnrollment.enableCloudForEnrolledAccount(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: "cloudPush.enabled"))
        XCTAssertTrue(defaults.bool(forKey: ServerScoringSettings.defaultsKey))
        XCTAssertFalse(defaults.bool(forKey: "cloudPush.wifiOnly"))
    }

    func testReadingWitnessedSourceDoesNotRewriteDefaultsOrInvalidateViews() throws {
        let name = "CloudSourceReadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(SourceCountingDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = EnrollmentMemoryBackend()
        let sourceStore = CloudInstallationSourceStore(backend: backend)
        defaults.set(source, forKey: "cloudPush.sourceId")
        try sourceStore.save(source)
        defaults.sourceWrites = 0
        for _ in 0..<10 {
            XCTAssertEqual(CloudPushSettings.sourceId(defaults: defaults, sourceStore: sourceStore), source)
        }
        XCTAssertEqual(defaults.sourceWrites, 0)
    }

    func testUnavailableSourceWitnessDoesNotCreateAnIdentityBeforeRecovery() throws {
        let name = "CloudSourceLockedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(SourceCountingDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = EnrollmentMemoryBackend()
        let sourceStore = CloudInstallationSourceStore(backend: backend)
        backend.failRead = true
        XCTAssertEqual(CloudPushSettings.sourceId(defaults: defaults, sourceStore: sourceStore), "")
        XCTAssertNil(defaults.string(forKey: "cloudPush.sourceId"))
        XCTAssertEqual(defaults.sourceWrites, 0)
        backend.failRead = false
        let recovered = CloudPushSettings.sourceId(defaults: defaults, sourceStore: sourceStore)
        XCTAssertNotNil(UUID(uuidString: recovered))
        XCTAssertEqual(try sourceStore.load(), recovered)
        XCTAssertEqual(CloudPushSettings.sourceId(defaults: defaults, sourceStore: sourceStore), recovered)
    }

    func testUnavailableWitnessPreservesExistingSourceWithoutRewritingDefaults() throws {
        let name = "CloudSourceRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(SourceCountingDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = EnrollmentMemoryBackend()
        let sourceStore = CloudInstallationSourceStore(backend: backend)
        try sourceStore.save(source)
        defaults.set(source, forKey: "cloudPush.sourceId")
        defaults.sourceWrites = 0
        backend.failRead = true
        XCTAssertEqual(CloudPushSettings.sourceId(defaults: defaults, sourceStore: sourceStore), source)
        XCTAssertEqual(defaults.sourceWrites, 0)
        backend.failRead = false
        XCTAssertEqual(CloudPushSettings.sourceId(defaults: defaults, sourceStore: sourceStore), source)
        XCTAssertEqual(defaults.sourceWrites, 0)
    }

    func testSourceWitnessWriteFailureNeverPublishesUnwitnessedIdentity() throws {
        let name = "CloudSourceWriteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(SourceCountingDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let backend = EnrollmentMemoryBackend()
        let sourceStore = CloudInstallationSourceStore(backend: backend)
        backend.failWrite = true
        XCTAssertEqual(CloudPushSettings.sourceId(defaults: defaults, sourceStore: sourceStore), "")
        XCTAssertNil(defaults.string(forKey: "cloudPush.sourceId"))
        backend.failWrite = false
        let recovered = CloudPushSettings.sourceId(defaults: defaults, sourceStore: sourceStore)
        XCTAssertEqual(try sourceStore.load(), recovered)
        XCTAssertNotNil(UUID(uuidString: recovered))
    }

    func testSignOutPreventsDelayedEnrollmentFromRestoringCredentialOrClaimingOwner() throws {
        let backend = EnrollmentMemoryBackend(), controller = CloudEnrollmentSessionController()
        let store = CloudEnrollmentCredentialStore(backend: backend), ownerStore = CloudEnrollmentOwnerStore(backend: backend)
        let pending = controller.begin()
        try controller.clear(store: store)
        XCTAssertThrowsError(try controller.activate(credential(), sourceId: source, request: pending,
                                                     store: store, ownerStore: ownerStore)) {
            XCTAssertEqual($0 as? CloudEnrollmentError, .superseded)
        }
        XCTAssertNil(try store.load(sourceId: source))
        XCTAssertNil(try ownerStore.load())
    }

    func testLatestEnrollmentAttemptWinsBeforeAnyOwnerBinding() throws {
        let backend = EnrollmentMemoryBackend(), controller = CloudEnrollmentSessionController()
        let store = CloudEnrollmentCredentialStore(backend: backend), ownerStore = CloudEnrollmentOwnerStore(backend: backend)
        let old = controller.begin(), latest = controller.begin()
        try controller.activate(credential(), sourceId: source, request: latest, store: store, ownerStore: ownerStore)
        XCTAssertThrowsError(try controller.activate(credential(owner: otherOwner), sourceId: source,
                                                     request: old, store: store, ownerStore: ownerStore))
        XCTAssertEqual(try ownerStore.load(), owner)
        XCTAssertEqual(try store.load(sourceId: source)?.userId, owner)
    }

    func testOwnerWitnessSurvivesSignOutAndRefusesDifferentAccount() throws {
        let backend = EnrollmentMemoryBackend(), controller = CloudEnrollmentSessionController()
        let store = CloudEnrollmentCredentialStore(backend: backend), ownerStore = CloudEnrollmentOwnerStore(backend: backend)
        try controller.activate(credential(), sourceId: source, request: controller.begin(), store: store, ownerStore: ownerStore)
        try controller.clear(store: store)
        XCTAssertEqual(try ownerStore.load(), owner)
        XCTAssertThrowsError(try controller.activate(credential(owner: otherOwner), sourceId: source,
                                                     request: controller.begin(), store: store, ownerStore: ownerStore)) {
            XCTAssertEqual($0 as? CloudEnrollmentError, .ownerMismatch)
        }
        XCTAssertNil(controller.current(sourceId: source, store: store, ownerStore: ownerStore))
        try controller.activate(credential(), sourceId: source, request: controller.begin(), store: store, ownerStore: ownerStore)
        XCTAssertEqual(controller.current(sourceId: source, store: store, ownerStore: ownerStore)?.userId, owner)
    }

    func testOldUnauthorizedResponseCannotClearRotatedCredential() throws {
        let backend = EnrollmentMemoryBackend(), controller = CloudEnrollmentSessionController()
        let store = CloudEnrollmentCredentialStore(backend: backend), ownerStore = CloudEnrollmentOwnerStore(backend: backend)
        let previous = credential()
        try controller.activate(previous, sourceId: source, request: controller.begin(), store: store, ownerStore: ownerStore)
        let rotated = credential(token: "noop_" + String(repeating: "z", count: 43))
        try controller.activate(rotated, sourceId: source, request: controller.begin(), store: store, ownerStore: ownerStore)
        XCTAssertFalse(controller.clear(ifUploadToken: previous.uploadToken, ownerId: owner, sourceId: source, store: store))
        XCTAssertEqual(controller.current(sourceId: source, store: store, ownerStore: ownerStore), rotated)
    }

    func testUnwitnessedOrWrongSourceCredentialIsNeverActive() throws {
        let backend = EnrollmentMemoryBackend(), controller = CloudEnrollmentSessionController()
        let store = CloudEnrollmentCredentialStore(backend: backend), ownerStore = CloudEnrollmentOwnerStore(backend: backend)
        try store.save(credential(), sourceId: source)
        XCTAssertNil(controller.current(sourceId: source, store: store, ownerStore: ownerStore))
        try ownerStore.bind(ownerId: owner)
        XCTAssertNotNil(controller.current(sourceId: source, store: store, ownerStore: ownerStore))
        XCTAssertNil(controller.current(sourceId: "44444444-4444-4444-8444-444444444444", store: store, ownerStore: ownerStore))
    }

    func testFailedKeychainDeletionSuspendsCurrentProcess() throws {
        let backend = EnrollmentMemoryBackend(), controller = CloudEnrollmentSessionController()
        let store = CloudEnrollmentCredentialStore(backend: backend), ownerStore = CloudEnrollmentOwnerStore(backend: backend)
        try controller.activate(credential(), sourceId: source, request: controller.begin(), store: store, ownerStore: ownerStore)
        backend.failDelete = true
        XCTAssertThrowsError(try controller.clear(store: store))
        XCTAssertNil(controller.current(sourceId: source, store: store, ownerStore: ownerStore))
        XCTAssertEqual(try ownerStore.load(), owner)
    }

    func testScoreReadUsesPersonalTokenAndExactDeviceWithFleetAuthorization() throws {
        let request = try ServerScoreClient.scoreRequest(base: URL(string: "https://example.test")!, anon: "public-anon",
            fleetToken: "fleet", credential: credential(), day: "2026-09-20", deviceId: "whoop-ABCD123456")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(credential().uploadToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-NOOP-Fleet-Token"), "fleet")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "deviceId" })?.value, "whoop-ABCD123456")
        XCTAssertThrowsError(try ServerScoreClient.scoreRequest(base: URL(string: "https://example.test")!, anon: "public",
            fleetToken: "fleet", credential: credential(), day: "2026-09-20", deviceId: " "))
    }

    func testRegistrationReceiptKeysSeparateEndpointsOwnersSourcesAndStraps() throws {
        let first = URL(string: "https://first.example.test")!, second = URL(string: "https://second.example.test")!
        let anotherSource = CloudEnrollmentCredential(userId: owner, sourceId: otherOwner,
            tokenId: credential().tokenId, uploadToken: credential().uploadToken)
        let keys = [
            ServerScoreClient.deviceMappingKey(credential(), "strap-a", base: first),
            ServerScoreClient.deviceMappingKey(credential(), "strap-a", base: second),
            ServerScoreClient.deviceMappingKey(credential(owner: otherOwner), "strap-a", base: first),
            ServerScoreClient.deviceMappingKey(anotherSource, "strap-a", base: first),
            ServerScoreClient.deviceMappingKey(credential(), "strap-b", base: first),
        ]
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testScoreResponseRejectsWrongUserSourceLocalDeviceOrCanonicalDevice() throws {
        let canonical = "55555555-5555-4555-8555-555555555555"
        let identity: [String: Any] = ["userId": owner, "sourceId": source, "deviceId": canonical, "externalDeviceId": "strap-a"]
        let overlay: [String: Any] = ["schema_version": 2, "user_id": owner, "day": "2026-09-20",
            "algorithm_version": "per_feature", "features": ["sleep": ["status": "unavailable", "device_id": canonical,
                "algorithm_version": "frwhoop-physiology-2", "reason": "awaiting_result"]], "nights": [], "daily": [:], "stale": true]
        func bytes(_ changed: [String: Any], overlayChanged: [String: Any]? = nil) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["identity": changed, "server_scoring": overlayChanged ?? overlay])
        }
        XCTAssertEqual(try ServerScoreClient.parseEnrolledSnapshot(bytes(identity), day: "2026-09-20",
            credential: credential(), deviceId: "strap-a").canonicalDeviceId, canonical)
        for (key, value) in [("userId", otherOwner), ("sourceId", otherOwner), ("externalDeviceId", "strap-b"), ("deviceId", otherOwner)] {
            var changed = identity; changed[key] = value
            XCTAssertThrowsError(try ServerScoreClient.parseEnrolledSnapshot(bytes(changed), day: "2026-09-20",
                credential: credential(), deviceId: "strap-a"), "must reject \(key)")
        }
    }

    func testUnavailableFeatureWithoutDeviceDoesNotDiscardOtherQualifiedResults() throws {
        let canonical = "55555555-5555-4555-8555-555555555555"
        let identity: [String: Any] = ["userId": owner, "sourceId": source, "deviceId": canonical, "externalDeviceId": "strap-a"]
        func bytes(status: String, missingDevice: String? = nil) throws -> Data {
            var unavailable: [String: Any] = ["status": status, "reason": "unqualified_version"]
            if let missingDevice { unavailable["device_id"] = missingDevice }
            return try JSONSerialization.data(withJSONObject: ["identity": identity, "server_scoring": [
                "schema_version": 2, "user_id": owner, "day": "2026-09-20", "algorithm_version": "per_feature",
                "features": ["sleep": ["status": "fresh", "device_id": canonical,
                    "algorithm_version": "frwhoop-physiology-2"], "respiration": unavailable],
                "nights": [], "daily": [:], "stale": true]])
        }
        let result = try ServerScoreClient.parseEnrolledSnapshot(bytes(status: "unavailable"), day: "2026-09-20",
            credential: credential(), deviceId: "strap-a")
        XCTAssertEqual(result.cache.features["sleep"]?.deviceId, canonical)
        XCTAssertEqual(result.cache.features["respiration"]?.status, "unavailable")
        for status in ["fresh", "stale", "pending"] {
            XCTAssertThrowsError(try ServerScoreClient.parseEnrolledSnapshot(bytes(status: status), day: "2026-09-20",
                credential: credential(), deviceId: "strap-a"))
        }
        XCTAssertThrowsError(try ServerScoreClient.parseEnrolledSnapshot(bytes(status: "unavailable", missingDevice: otherOwner),
            day: "2026-09-20", credential: credential(), deviceId: "strap-a"))
    }
}

private final class EnrollmentMemoryBackend: CloudEnrollmentKeychainBackend {
    private var values: [String: Data] = [:]
    var failDelete = false
    var failRead = false
    var failWrite = false
    func read(service: String, account: String) throws -> Data? {
        if failRead { throw CloudEnrollmentError.credentialStorageUnavailable }
        return values[service + ":" + account]
    }
    func write(_ data: Data, service: String, account: String) throws {
        if failWrite { throw CloudEnrollmentError.credentialStorageUnavailable }
        values[service + ":" + account] = data
    }
    func delete(service: String, account: String) throws {
        if failDelete { throw CloudEnrollmentError.credentialStorageUnavailable }
        values.removeValue(forKey: service + ":" + account)
    }
}

private final class SourceCountingDefaults: UserDefaults {
    var sourceWrites = 0
    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "cloudPush.sourceId" { sourceWrites += 1 }
        super.set(value, forKey: defaultName)
    }
}
