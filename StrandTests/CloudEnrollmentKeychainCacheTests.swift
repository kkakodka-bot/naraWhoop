import Foundation
import XCTest
@testable import Strand

final class CloudEnrollmentKeychainCacheTests: XCTestCase {
    private final class Backend: CloudEnrollmentKeychainBackend {
        var values: [String: Data] = [:]
        var reads = 0
        var fails = false
        enum Failure: Error { case unavailable }
        func read(service: String, account: String) throws -> Data? {
            reads += 1
            if fails { throw Failure.unavailable }
            return values[account]
        }
        func write(_ data: Data, service: String, account: String) throws {
            if fails { throw Failure.unavailable }
            values[account] = data
        }
        func delete(service: String, account: String) throws {
            if fails { throw Failure.unavailable }
            values[account] = nil
        }
    }

    func testHotReadsUseOneKeychainReadAndExpiredValuesAreRevalidated() throws {
        let backend = Backend()
        backend.values["credential"] = Data([1])
        var clock = 0.0
        let cache = CachedCloudEnrollmentKeychain(backend: backend, now: { clock })
        for _ in 0..<10_000 {
            XCTAssertEqual(try cache.read(service: "enrollment", account: "credential"), Data([1]))
        }
        XCTAssertEqual(backend.reads, 1)
        clock = 1
        backend.values["credential"] = Data([2])
        XCTAssertEqual(try cache.read(service: "enrollment", account: "credential"), Data([2]))
        XCTAssertEqual(backend.reads, 2)
    }

    func testRotationAndRevocationInvalidateImmediately() throws {
        let backend = Backend()
        let cache = CachedCloudEnrollmentKeychain(backend: backend)
        try cache.write(Data([1]), service: "enrollment", account: "credential")
        XCTAssertEqual(try cache.read(service: "enrollment", account: "credential"), Data([1]))
        try cache.write(Data([2]), service: "enrollment", account: "credential")
        XCTAssertEqual(try cache.read(service: "enrollment", account: "credential"), Data([2]))
        try cache.delete(service: "enrollment", account: "credential")
        XCTAssertNil(try cache.read(service: "enrollment", account: "credential"))
    }

    func testProtectedStorageFailureAndMissingCredentialAreRetried() throws {
        let backend = Backend()
        let cache = CachedCloudEnrollmentKeychain(backend: backend)
        backend.fails = true
        XCTAssertThrowsError(try cache.read(service: "enrollment", account: "credential"))
        backend.fails = false
        XCTAssertNil(try cache.read(service: "enrollment", account: "credential"))
        backend.values["credential"] = Data([1])
        XCTAssertEqual(try cache.read(service: "enrollment", account: "credential"), Data([1]))
        XCTAssertEqual(backend.reads, 3)
    }

    func testFailedDeleteCannotReturnPreviouslyCachedCredential() throws {
        let backend = Backend()
        backend.values["credential"] = Data([1])
        let cache = CachedCloudEnrollmentKeychain(backend: backend)
        _ = try cache.read(service: "enrollment", account: "credential")
        backend.fails = true
        XCTAssertThrowsError(try cache.delete(service: "enrollment", account: "credential"))
        XCTAssertThrowsError(try cache.read(service: "enrollment", account: "credential"))
    }
}
