import XCTest
import Foundation
import NoopPush
import WhoopStore
@testable import Strand

@MainActor
final class ImuPushSourceBootstrapTests: XCTestCase {
    private struct Fixture: @unchecked Sendable {
        let directory: URL
        let scope: AccountScope
        let session: ImuSessionFileStore
        let continuous: ImuSessionFileStore

        func make() throws -> CloudImuPushSource {
            try CloudImuPushSource(scope: scope, directory: directory.appendingPathComponent("RawImuUploadIndex"),
                                  sessionStore: session, continuousStore: continuous)
        }
        @MainActor func bootstrap(scope override: AccountScope? = nil) -> ImuPushSourceBootstrap {
            ImuPushSourceBootstrap(scope: override ?? scope, directory: directory,
                                   sessionStore: session, continuousStore: continuous)
        }
    }

    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func fixture() throws -> Fixture {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let suite = "ImuPushSourceBootstrapTests.\(id)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let scope = try AccountScope(projectURL: "https://fixture.invalid", userID: "11111111-1111-4111-8111-111111111111")
        let capture = DurableIngestScope(environment: scope.projectURL, accountID: scope.userID, deviceID: "strap")
        return Fixture(directory: directory, scope: scope,
            session: ImuSessionFileStore(directory: directory.appendingPathComponent("RawImuSessions"), defaults: defaults, captureScope: capture),
            continuous: ImuSessionFileStore(directory: directory.appendingPathComponent("RawImuContinuous"),
                defaultsKey: "continuous", defaults: defaults, captureScope: capture))
    }

    func testConcurrentPreparationOpensOffMainOnceAndNeverReplacesPublishedMux() async throws {
        let f = try fixture()
        let attempts = Attempts()
        let entered = expectation(description: "off-main initializer")
        let release = DispatchSemaphore(value: 0)
        let bootstrap = ImuPushSourceBootstrap {
            XCTAssertFalse(Thread.isMainThread)
            _ = attempts.next()
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
            return try f.make()
        }
        let first = Task { try await bootstrap.prepare() }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { try await bootstrap.prepare() }
        for _ in 0..<5 { await Task.yield() }
        release.signal()
        let a = try await first.value
        let b = try await second.value
        let c = try await bootstrap.prepare()
        XCTAssertTrue(a === b && b === c && c === bootstrap.source)
        XCTAssertEqual(attempts.count, 1)
    }

    func testFirstBindingHasBothCapturedStoresAndSameSecondMembers() async throws {
        let f = try fixture()
        for store in [f.session, f.continuous] {
            store.register(id: "window", deviceId: "strap", fromMs: 1_000, toMs: 2_000)
            XCTAssertEqual(store.append(deviceId: "strap", ts: 1, columns: Array(repeating: 1, count: 600), receivedAtMs: 1_000), 1)
        }
        let bootstrap = f.bootstrap()
        let source = try await bootstrap.prepare()
        let store = try await WhoopStore.inMemory()
        try CloudPushCaptureBindings.bind(db: store.registryWriter, scope: f.scope,
            sourceID: "22222222-2222-4222-8222-222222222222", imuSource: source)
        let bound = try XCTUnwrap(CloudPushCaptureBindings.binding(for: store.registryWriter)?.imuSource as? CloudImuPushSource)
        XCTAssertTrue(bound === source && bound === bootstrap.source)
        let rows = try bound.indexedPushRows(deviceId: "strap", afterRowId: 0, limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.rowId)).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("RawImuUploadIndex/membership.sqlite").path))
    }

    func testInitializationFailureNeverBindsEmptyLaneAndRetryUsesCapturedStores() async throws {
        let f = try fixture()
        let store = try await WhoopStore.inMemory()
        let attempts = Attempts()
        let bootstrap = ImuPushSourceBootstrap {
            XCTAssertFalse(Thread.isMainThread)
            if attempts.next() == 1 { throw CocoaError(.fileWriteOutOfSpace) }
            return try f.make()
        }
        do {
            let source = try await bootstrap.prepare()
            try CloudPushCaptureBindings.bind(db: store.registryWriter, scope: f.scope,
                sourceID: "22222222-2222-4222-8222-222222222222", imuSource: source)
            XCTFail("failed initialization must not publish or bind")
        } catch { }
        XCTAssertNil(bootstrap.source)
        XCTAssertNil(CloudPushCaptureBindings.binding(for: store.registryWriter))
        let source = try await bootstrap.prepare()
        XCTAssertTrue(source === bootstrap.source)
        XCTAssertEqual(attempts.count, 2)
    }

    func testRetirementDuringConstructionCannotPublishOrRetry() async throws {
        let f = try fixture()
        let entered = expectation(description: "construction started")
        let release = DispatchSemaphore(value: 0)
        let bootstrap = ImuPushSourceBootstrap {
            entered.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
            return try f.make()
        }
        let task = Task { try await bootstrap.prepare() }
        await fulfillment(of: [entered], timeout: 2)
        bootstrap.shutdownForAccountChange()
        release.signal()
        do { _ = try await task.value; XCTFail("retired source cannot publish") } catch { }
        XCTAssertNil(bootstrap.source)
        do { _ = try await bootstrap.prepare(); XCTFail("retired bootstrap cannot retry") }
        catch { XCTAssertEqual(error as? ImuPushSourceBootstrap.Failure, .retired) }
    }

    func testUnassignedOrMissingDirectoryDoesNotCreateIndexOrUseGlobals() async throws {
        let f = try fixture()
        let cases: [(AccountScope?, URL?, ImuPushSourceBootstrap.Failure)] = [
            (nil, f.directory, .unassigned), (f.scope, nil, .missingStorageDirectory)]
        for (scope, directory, expected) in cases {
            let bootstrap = ImuPushSourceBootstrap(scope: scope, directory: directory,
                sessionStore: f.session, continuousStore: f.continuous)
            do { _ = try await bootstrap.prepare(); XCTFail("must require assigned storage") }
            catch { XCTAssertEqual(error as? ImuPushSourceBootstrap.Failure, expected) }
            XCTAssertNil(bootstrap.source)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("RawImuUploadIndex").path))
    }

    func testActualIndexFilesystemFailurePropagatesAndCanRetry() async throws {
        let f = try fixture()
        let index = f.directory.appendingPathComponent("RawImuUploadIndex")
        try Data([1]).write(to: index)
        let bootstrap = f.bootstrap()
        do { _ = try await bootstrap.prepare(); XCTFail("a file cannot act as the index directory") } catch { }
        XCTAssertNil(bootstrap.source)
        try FileManager.default.removeItem(at: index)
        let source = try await bootstrap.prepare()
        XCTAssertTrue(source === bootstrap.source)
    }

    func testOtherAccountCannotAdoptCapturedStores() async throws {
        let f = try fixture()
        let other = try AccountScope(projectURL: f.scope.projectURL, userID: "22222222-2222-4222-8222-222222222222")
        let bootstrap = f.bootstrap(scope: other)
        do { _ = try await bootstrap.prepare(); XCTFail("cannot relabel either captured store") }
        catch { XCTAssertTrue(error is ImuPushSourceError) }
        XCTAssertNil(bootstrap.source)
    }
}
