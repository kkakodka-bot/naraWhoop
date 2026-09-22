import XCTest
import Foundation
@testable import InstallationLifecycleHarness

final class LifecycleTests: XCTestCase {
    let ownerA = "11111111-1111-4111-8111-111111111111"
    let ownerB = "22222222-2222-4222-8222-222222222222"
    let sourceA = "33333333-3333-4333-8333-333333333333"
    func credential(owner: String, source: String) -> CloudEnrollmentCredential {
        .init(userId: owner, sourceId: source, tokenId: UUID().uuidString.lowercased(),
              uploadToken: "noop_" + String(repeating: "a", count: 43))
    }
    func testRetirementJournalSurvivesInterruptionAndNeverReassignsOldSource() throws {
        let backend = MemoryBackend()
        let journal = CloudInstallationRetirementStore(backend: backend)
        let owner = CloudEnrollmentOwnerStore(backend: backend)
        let credentials = CloudEnrollmentCredentialStore(backend: backend)
        let source = CloudInstallationSourceStore(backend: backend)
        let a = credential(owner: ownerA, source: sourceA)
        try owner.bind(ownerId: ownerA); try credentials.save(a, sourceId: sourceA); try source.save(sourceA)
        let pending = try journal.begin(a)
        try credentials.clear()
        XCTAssertEqual(try CloudInstallationRetirementStore(backend: backend).load(), pending)
        XCTAssertThrowsError(try owner.bind(ownerId: ownerB))
        XCTAssertNotEqual(pending.nextSourceId, sourceA)
        let suite = "retirement-test.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        backend.failWrites = true
        XCTAssertThrowsError(try journal.complete(pending, credentialStore: credentials, ownerStore: owner, sourceStore: source, defaults: defaults))
        XCTAssertEqual(try journal.load(), pending)
        XCTAssertEqual(try owner.load(), ownerA)
        backend.failWrites = false
        try journal.complete(pending, credentialStore: credentials, ownerStore: owner, sourceStore: source, defaults: defaults)
        XCTAssertNil(try journal.load()); XCTAssertNil(try owner.load())
        XCTAssertEqual(try source.load(), pending.nextSourceId)
        XCTAssertTrue(try journal.hasRetiredInstallation())
        XCTAssertEqual(defaults.string(forKey:"cloudPush.sourceId"),pending.nextSourceId)
        try owner.bind(ownerId: ownerB)
        let b = credential(owner: ownerB, source: pending.nextSourceId)
        try credentials.save(b,sourceId:pending.nextSourceId)
        XCTAssertEqual(try credentials.load(sourceId:pending.nextSourceId),b)
        XCTAssertEqual(String(data:try XCTUnwrap(backend.values["noop.cloudEnrollment/retired-owner.\(sourceA)"]),encoding:.utf8),ownerA)
    }
    func testLateActivationFromRetiredAIsFencedBeforeB() throws {
        let backend=MemoryBackend(); let owner=CloudEnrollmentOwnerStore(backend:backend)
        let store=CloudEnrollmentCredentialStore(backend:backend); let controller=CloudEnrollmentSessionController()
        let request=controller.begin()
        try controller.clear(store:store)
        XCTAssertThrowsError(try controller.activate(credential(owner:ownerA,source:sourceA),sourceId:sourceA,
            request:request,store:store,ownerStore:owner))
        XCTAssertNil(try owner.load())
    }
    func testJournalDoesNotAcceptAnotherOwnerWhileRetirementIsPending() throws {
        let journal=CloudInstallationRetirementStore(backend:MemoryBackend())
        let a=credential(owner:ownerA,source:sourceA)
        let first=try journal.begin(a)
        XCTAssertEqual(try journal.begin(a),first)
        XCTAssertThrowsError(try journal.begin(credential(owner:ownerB,source:sourceA)))
        XCTAssertEqual(try journal.load(),first)
    }
    func testSerialWitnessSurvivesAdoptionRetryAndRetirementDoesNotReassignIt() throws {
        let backend = MemoryBackend()
        let store = CloudWearableAssociationStore(backend: backend)
        let a = credential(owner: ownerA, source: sourceA)
        try store.record(provisional: "local-pairing", serial: "SYNTH001", credential: a)
        let pending = try XCTUnwrap(CloudWearableAssociationStore(backend: backend).pending(a).first)
        try store.acknowledge(pending, credential: a)
        try store.record(provisional: "local-pairing", serial: "SYNTH001", credential: a)
        XCTAssertTrue(try store.pending(a).isEmpty)
        XCTAssertThrowsError(try store.record(provisional: "local-pairing", serial: "SYNTH002", credential: a))
        XCTAssertThrowsError(try store.pending(a))
        let b = credential(owner: ownerB, source: UUID().uuidString.lowercased())
        XCTAssertTrue(try store.pending(b).isEmpty)
        try store.record(provisional: "local-pairing", serial: "SYNTH002", credential: b)
        XCTAssertEqual(try store.pending(b).first?.serial, "SYNTH002")
    }
}
private final class MemoryBackend: CloudEnrollmentKeychainBackend {
    var values:[String:Data]=[:]
    var failWrites=false
    func read(service:String,account:String)throws->Data? { values[service+"/"+account] }
    func write(_ data:Data,service:String,account:String)throws {
        if failWrites {throw URLError(.cannotWriteToFile)}
        values[service+"/"+account]=data
    }
    func delete(service:String,account:String)throws { values.removeValue(forKey:service+"/"+account) }
}
