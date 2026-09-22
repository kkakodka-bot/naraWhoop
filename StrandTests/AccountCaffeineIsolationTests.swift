import Foundation
import XCTest
@testable import Strand

@MainActor
final class AccountCaffeineIsolationTests: XCTestCase {
    func testAccountSwitchDoesNotAdoptOrEraseAnotherOwnersIntakes() throws {
        let aName = "test.caffeine.a." + UUID().uuidString
        let bName = "test.caffeine.b." + UUID().uuidString
        let aDefaults = try XCTUnwrap(UserDefaults(suiteName: aName))
        let bDefaults = try XCTUnwrap(UserDefaults(suiteName: bName))
        defer { aDefaults.removePersistentDomain(forName: aName); bDefaults.removePersistentDomain(forName: bName) }
        let now = Date()
        let a = CaffeineLogStore(defaults: aDefaults, now: { now })
        a.log(at: now, mg: 80)
        let retained = aDefaults.data(forKey: "caffeine.intakes")
        a.invalidate()
        let b = CaffeineLogStore(defaults: bDefaults, now: { now })
        XCTAssertTrue(a.intakes.isEmpty)
        XCTAssertTrue(b.intakes.isEmpty)
        // A callback that completes after logout cannot resurrect the old visible store or mutate disk.
        a.replaceImported([CaffeineIntake(at: now, mg: 150)])
        a.log(at: now, mg: 200)
        XCTAssertTrue(a.intakes.isEmpty)
        XCTAssertEqual(aDefaults.data(forKey: "caffeine.intakes"), retained)
        let returned = CaffeineLogStore(defaults: aDefaults, now: { now })
        XCTAssertEqual(returned.intakes.count, 1)
        XCTAssertEqual(returned.intakes.first?.mg, 80)
        b.log(at: now, mg: 40)
        XCTAssertEqual(returned.intakes.first?.mg, 80)
    }
}
