import Foundation
import NoopPush
import XCTest
@testable import Strand

final class CloudEnrollmentTests: XCTestCase {
    private let userId = "11111111-1111-4111-8111-111111111111"
    private let sourceId = "22222222-2222-4222-8222-222222222222"
    private let otherSourceId = "33333333-3333-4333-8333-333333333333"
    private let tokenId = "44444444-4444-4444-8444-444444444444"
    private let fleetToken = "fleet-secret"
    private let uploadToken = "noop_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"

    override func setUp() {
        super.setUp()
        CloudEnrollmentURLProtocolStub.reset()
    }

    override func tearDown() {
        CloudEnrollmentURLProtocolStub.reset()
        super.tearDown()
    }

    func testEnrollmentPostsExactContractAndReturnsCredential() async throws {
        CloudEnrollmentURLProtocolStub.response = .init(
            status: 200,
            body: enrollmentResponse(sourceId: sourceId)
        )
        let client = CloudEnrollmentClient(session: CloudEnrollmentURLProtocolStub.session())

        let credential = try await client.enroll(
            code: "CODE-1234",
            endpoint: try endpoint(),
            fleetToken: fleetToken,
            sourceId: sourceId,
            platform: .iOS,
            appVersion: "9.2.0"
        )

        XCTAssertEqual(
            CloudEnrollmentCredential(
                userId: userId,
                sourceId: sourceId,
                tokenId: tokenId,
                uploadToken: uploadToken
            ),
            credential
        )
        let request = try XCTUnwrap(CloudEnrollmentURLProtocolStub.requests.first)
        XCTAssertEqual("https://receiver.example/functions/v1/push/enroll", request.url?.absoluteString)
        XCTAssertEqual("POST", request.httpMethod)
        XCTAssertEqual("Bearer \(fleetToken)", request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: CloudPushTransport.fleetTokenHeader))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String]
        )
        XCTAssertEqual(Set(["code", "sourceId", "platform", "appVersion"]), Set(object.keys))
        XCTAssertEqual("CODE-1234", object["code"])
        XCTAssertEqual(sourceId, object["sourceId"])
        XCTAssertEqual("ios", object["platform"])
        XCTAssertEqual("9.2.0", object["appVersion"])
    }

    func testEnrollmentRejectsSourceMismatchAndUnexpectedMembers() async throws {
        let client = CloudEnrollmentClient(session: CloudEnrollmentURLProtocolStub.session())
        CloudEnrollmentURLProtocolStub.response = .init(
            status: 200,
            body: enrollmentResponse(sourceId: otherSourceId)
        )
        await assertInvalidResponse(client: client)

        var object = try JSONSerialization.jsonObject(with: enrollmentResponse(sourceId: sourceId)) as! [String: Any]
        object["unexpected"] = true
        CloudEnrollmentURLProtocolStub.response = .init(
            status: 200,
            body: try JSONSerialization.data(withJSONObject: object)
        )
        await assertInvalidResponse(client: client)
    }

    func testEnrollmentVerificationRequiresMatchingCapabilitiesIdentity() async throws {
        let client = CloudEnrollmentClient(session: CloudEnrollmentURLProtocolStub.session())
        let credential = CloudEnrollmentCredential(userId: userId, sourceId: sourceId,
                                                    tokenId: tokenId, uploadToken: uploadToken)
        func response(owner: String, source: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "capabilities", "protocolVersion": "1.2",
                "receiverStateId": "55555555-5555-4555-8555-555555555555", "userId": owner,
                "sourceId": source, "streams": ["hrSample"]])
        }
        CloudEnrollmentURLProtocolStub.response = .init(status: 200, body: try response(owner: userId, source: sourceId))
        try await client.verify(credential, endpoint: endpoint(), fleetToken: fleetToken)
        let request = try XCTUnwrap(CloudEnrollmentURLProtocolStub.requests.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(uploadToken)")
        XCTAssertEqual(request.value(forHTTPHeaderField: CloudPushTransport.fleetTokenHeader), fleetToken)
        for (owner, source) in [(otherSourceId, sourceId), (userId, otherSourceId)] {
            CloudEnrollmentURLProtocolStub.response = .init(status: 200, body: try response(owner: owner, source: source))
            do {
                try await client.verify(credential, endpoint: endpoint(), fleetToken: fleetToken)
                XCTFail("mismatched enrollment must be refused")
            } catch {
                XCTAssertEqual(error as? CloudEnrollmentError, .invalidResponse)
            }
        }
    }

    func testEnrollmentRejectsWrongTypeProtocolAndMalformedToken() async throws {
        let client = CloudEnrollmentClient(session: CloudEnrollmentURLProtocolStub.session())
        for mutation in [
            ["type": "capabilities"],
            ["protocolVersion": "1.0"],
            ["uploadToken": "not-an-upload-token"],
            ["uploadToken": "noop_" + String(repeating: "é", count: 43)],
        ] {
            var object = try JSONSerialization.jsonObject(with: enrollmentResponse(sourceId: sourceId)) as! [String: Any]
            for (key, value) in mutation { object[key] = value }
            CloudEnrollmentURLProtocolStub.response = .init(
                status: 200,
                body: try JSONSerialization.data(withJSONObject: object)
            )
            await assertInvalidResponse(client: client)
        }
    }

    func testRejectedEnrollmentErrorDoesNotEchoSecrets() async throws {
        let serverBody = Data("rejected \(fleetToken) CODE-1234 \(uploadToken)".utf8)
        CloudEnrollmentURLProtocolStub.response = .init(status: 403, body: serverBody)
        let client = CloudEnrollmentClient(session: CloudEnrollmentURLProtocolStub.session())

        do {
            _ = try await client.enroll(
                code: "CODE-1234",
                endpoint: try endpoint(),
                fleetToken: fleetToken,
                sourceId: sourceId,
                platform: .iOS,
                appVersion: "9.2.0"
            )
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? CloudEnrollmentError, .rejected(statusCode: 403))
            let description = error.localizedDescription
            XCTAssertFalse(description.contains(fleetToken))
            XCTAssertFalse(description.contains("CODE-1234"))
            XCTAssertFalse(description.contains(uploadToken))
        }
    }

    func testCredentialStoreRoundTripAndSourceMismatchClearsRecord() throws {
        let backend = MemoryEnrollmentKeychain()
        let store = CloudEnrollmentCredentialStore(backend: backend)
        let credential = CloudEnrollmentCredential(
            userId: userId,
            sourceId: sourceId,
            tokenId: tokenId,
            uploadToken: uploadToken
        )

        try store.save(credential, sourceId: sourceId)
        XCTAssertEqual(credential, try store.load(sourceId: sourceId))
        XCTAssertNil(try store.load(sourceId: otherSourceId))
        XCTAssertEqual(1, backend.deleteCount)
        XCTAssertNil(backend.data)
    }

    func testCredentialStoreClearsCorruptOrOldVersionRecords() throws {
        let backend = MemoryEnrollmentKeychain()
        let store = CloudEnrollmentCredentialStore(backend: backend)
        backend.data = Data("not-json".utf8)
        XCTAssertNil(try store.load(sourceId: sourceId))
        XCTAssertEqual(1, backend.deleteCount)

        let old = CloudEnrollmentCredential(
            version: 0,
            userId: userId,
            sourceId: sourceId,
            tokenId: tokenId,
            uploadToken: uploadToken
        )
        backend.data = try JSONEncoder().encode(old)
        XCTAssertNil(try store.load(sourceId: sourceId))
        XCTAssertEqual(2, backend.deleteCount)
    }

    func testProgressNamespaceChangesWithUserAndSourceButNotTokenRotation() throws {
        let endpoint = try endpoint()
        let first = CloudPushSettings.progressNamespace(
            userId: userId,
            sourceId: sourceId,
            endpoint: endpoint
        )
        XCTAssertEqual(first, CloudPushSettings.progressNamespace(
            userId: userId,
            sourceId: sourceId,
            endpoint: endpoint
        ))
        XCTAssertNotEqual(first, CloudPushSettings.progressNamespace(
            userId: "55555555-5555-4555-8555-555555555555",
            sourceId: sourceId,
            endpoint: endpoint
        ))
        XCTAssertNotEqual(first, CloudPushSettings.progressNamespace(
            userId: userId,
            sourceId: otherSourceId,
            endpoint: endpoint
        ))
    }

    func testPersistedSourceIdIsCanonicalizedWhenDeviceWitnessMatches() throws {
        let defaults = try testDefaults()
        let backend = MemoryEnrollmentKeychain()
        let sourceStore = CloudInstallationSourceStore(backend: backend)
        let uppercase = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        let canonical = uppercase.lowercased()
        defaults.set(uppercase, forKey: "cloudPush.sourceId")
        try sourceStore.save(canonical)

        XCTAssertEqual(
            canonical,
            CloudPushSettings.sourceId(defaults: defaults, sourceStore: sourceStore)
        )
        XCTAssertEqual(canonical, defaults.string(forKey: "cloudPush.sourceId"))
    }

    func testRestoredDefaultsWithoutDeviceWitnessMintsNewInstallationSource() throws {
        let defaults = try testDefaults()
        let backend = MemoryEnrollmentKeychain()
        let sourceStore = CloudInstallationSourceStore(backend: backend)
        defaults.set(sourceId, forKey: "cloudPush.sourceId")

        let replacement = CloudPushSettings.sourceId(defaults: defaults, sourceStore: sourceStore)

        XCTAssertNotEqual(sourceId, replacement)
        XCTAssertEqual(replacement, defaults.string(forKey: "cloudPush.sourceId"))
        XCTAssertEqual(replacement, try sourceStore.load())
        XCTAssertEqual(
            replacement,
            CloudPushSettings.sourceId(defaults: defaults, sourceStore: sourceStore)
        )
    }

    func testReinstallWithoutDefaultsDoesNotReuseSurvivingDeviceWitness() throws {
        let defaults = try testDefaults()
        let backend = MemoryEnrollmentKeychain()
        let sourceStore = CloudInstallationSourceStore(backend: backend)
        try sourceStore.save(sourceId)

        let replacement = CloudPushSettings.sourceId(defaults: defaults, sourceStore: sourceStore)

        XCTAssertNotEqual(sourceId, replacement)
        XCTAssertEqual(replacement, defaults.string(forKey: "cloudPush.sourceId"))
        XCTAssertEqual(replacement, try sourceStore.load())
    }

    private func testDefaults() throws -> UserDefaults {
        let suite = "CloudEnrollmentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func assertInvalidResponse(client: CloudEnrollmentClient) async {
        do {
            _ = try await client.enroll(
                code: "CODE-1234",
                endpoint: try! endpoint(),
                fleetToken: fleetToken,
                sourceId: sourceId,
                platform: .iOS,
                appVersion: "9.2.0"
            )
            XCTFail("expected invalid response")
        } catch {
            XCTAssertEqual(error as? CloudEnrollmentError, .invalidResponse)
        }
    }

    private func endpoint() throws -> PushValidEndpoint {
        guard case .valid(let endpoint) = PushEndpointPolicy.validate(
            "https://receiver.example/functions/v1/push"
        ) else {
            throw CloudEnrollmentError.notConfigured
        }
        return endpoint
    }

    private func enrollmentResponse(sourceId: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "enrollment",
            "protocolVersion": "1.1",
            "userId": userId,
            "sourceId": sourceId,
            "tokenId": tokenId,
            "uploadToken": uploadToken,
        ])
    }
}

final class CloudPushTransportIdentityTests: XCTestCase {
    private let userId = "11111111-1111-4111-8111-111111111111"
    private let sourceId = "22222222-2222-4222-8222-222222222222"
    private let uploadToken = "noop_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
    private let fleetToken = "fleet-secret"

    override func setUp() {
        super.setUp()
        CloudPushURLProtocolStub.reset()
    }

    override func tearDown() {
        CloudPushURLProtocolStub.reset()
        super.tearDown()
    }

    func testEveryReceiverRequestUsesPersonalBearerAndFleetHeader() async throws {
        let batch = try PushProtocol.appendBatch(
            table: .hrSample,
            sourceId: sourceId,
            deviceId: "strap-a",
            startCursor: nil,
            records: [PushAppendRecord(
                rowId: 1,
                key: ["ts": .int(100)],
                data: ["bpm": .int(60)]
            )]
        )
        let binary = try PushProtocol.binaryObjectBatch(
            table: .ppgWaveformSample,
            sourceId: sourceId,
            deviceId: "strap-a",
            startCursor: nil,
            rows: [.ppgWaveform(PushPpgWaveformRecord(
                rowId: 1,
                ts: 100,
                burstIndex: nil,
                samples: Data([1, 2, 3])
            ))],
            protocolVersion: PushProtocol.objectVersion
        )
        let lane = PushObjectLane(
            endpoint: "/functions/v1/push/objects",
            maxObjectBytes: Int64(PushProtocolLimits.maxObjectWireBytes),
            urlTtlSec: 300,
            streams: [.ppgWaveformSample]
        )
        CloudPushURLProtocolStub.responses = [
            .init(status: 200, body: try JSONSerialization.data(withJSONObject: [
                "type": "capabilities",
                "protocolVersion": PushProtocol.objectVersion,
                "receiverStateId": "55555555-5555-4555-8555-555555555555",
                "userId": userId,
                "sourceId": sourceId,
                "streams": ["hrSample", "ppgWaveformSample"],
            ])),
            .init(status: 200, body: Data()),
            .init(status: 200, body: try JSONSerialization.data(withJSONObject: [
                "type": "objectIntent",
                "protocolVersion": PushProtocol.objectVersion,
                "objectId": binary.objectId,
                "objectKey": "objects/test",
                "duplicate": true,
            ])),
            .init(status: 200, body: try JSONSerialization.data(withJSONObject: [
                "type": "objectAck",
                "protocolVersion": PushProtocol.objectVersion,
                "objectId": binary.objectId,
                "status": "ready",
                "objectKey": "objects/test",
                "duplicate": true,
            ])),
        ]
        let session = CloudPushURLProtocolStub.session()
        let transport = CloudPushTransport(
            endpoint: try endpoint(),
            uploadToken: uploadToken,
            fleetToken: fleetToken,
            session: session,
            uploadSession: session
        )

        guard case .available(let capabilities) = try await transport.capabilities() else {
            return XCTFail("expected capabilities")
        }
        XCTAssertEqual(userId, capabilities.userId)
        XCTAssertEqual(sourceId, capabilities.sourceId)
        _ = try await transport.post(batch)
        _ = try await transport.createObjectIntent(PushObjectManifest(batch: binary), lane: lane)
        _ = try await transport.completeObject(objectId: binary.objectId, lane: lane)

        XCTAssertEqual(4, CloudPushURLProtocolStub.requests.count)
        for request in CloudPushURLProtocolStub.requests {
            XCTAssertEqual("Bearer \(uploadToken)", request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(fleetToken, request.value(forHTTPHeaderField: CloudPushTransport.fleetTokenHeader))
        }
    }

    func testPresignedBucketPutCarriesOnlyRequiredHeaders() async throws {
        CloudPushURLProtocolStub.responses = [.init(status: 200, body: Data())]
        let session = CloudPushURLProtocolStub.session()
        let transport = CloudPushTransport(
            endpoint: try endpoint(),
            uploadToken: uploadToken,
            fleetToken: fleetToken,
            session: session,
            uploadSession: session
        )
        let intent = PushObjectIntent(
            objectId: "66666666-6666-4666-8666-666666666666",
            objectKey: "objects/test",
            uploadUrl: "https://bucket.example/upload",
            requiredHeaders: ["x-required": "signed-value"],
            expiresAt: nil,
            duplicate: false
        )

        try await transport.uploadObject(intent, body: Data([1, 2, 3]))

        let request = try XCTUnwrap(CloudPushURLProtocolStub.requests.first)
        XCTAssertEqual("signed-value", request.value(forHTTPHeaderField: "x-required"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: CloudPushTransport.fleetTokenHeader))
    }

    private func endpoint() throws -> PushValidEndpoint {
        guard case .valid(let endpoint) = PushEndpointPolicy.validate(
            "https://receiver.example/functions/v1/push"
        ) else {
            throw CloudEnrollmentError.notConfigured
        }
        return endpoint
    }
}

private final class MemoryEnrollmentKeychain: CloudEnrollmentKeychainBackend {
    var data: Data?
    var deleteCount = 0

    func read(service: String, account: String) throws -> Data? { data }
    func write(_ data: Data, service: String, account: String) throws { self.data = data }
    func delete(service: String, account: String) throws {
        data = nil
        deleteCount += 1
    }
}

private final class CloudEnrollmentURLProtocolStub: URLProtocol {
    struct Response {
        let status: Int
        let body: Data
    }

    nonisolated(unsafe) static var response = Response(status: 500, body: Data())
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        response = Response(status: 500, body: Data())
        requests = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudEnrollmentURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = capturedRequest.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            capturedRequest.httpBody = body
        }
        Self.requests.append(capturedRequest)
        let response = Self.response
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CloudPushURLProtocolStub: URLProtocol {
    struct Response {
        let status: Int
        let body: Data
    }

    nonisolated(unsafe) static var responses: [Response] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        responses = []
        requests = []
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudPushURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let response = Self.responses.isEmpty
            ? Response(status: 500, body: Data())
            : Self.responses.removeFirst()
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
