import XCTest
@testable import Strand

@MainActor
final class AccountLogIsolationTests: XCTestCase {
    func testAccountLogTailsAndLateCallbacksStayWithCapturedOwner() {
        let aSuite = "log-isolation-a-" + UUID().uuidString
        let bSuite = "log-isolation-b-" + UUID().uuidString
        let a = UserDefaults(suiteName: aSuite)!
        let b = UserDefaults(suiteName: bSuite)!
        defer { a.removePersistentDomain(forName: aSuite); b.removePersistentDomain(forName: bSuite) }
        a.set(["owner A previous session"], forKey: "strapLog.tail")
        b.set(["owner B previous session"], forKey: "strapLog.tail")
        let old = LiveState(defaults: a, logNamespace: aSuite)
        old.append(log: "owner A current")
        old.invalidateAccountRuntime()
        let next = LiveState(defaults: b, logNamespace: bSuite)
        next.append(log: "owner B current")
        next.clearBiometrics()
        old.append(log: "retired callback must not persist")
        old.clearBiometrics()
        let aText = LiveState.scheduledExportText(defaults: a)
        let bText = LiveState.scheduledExportText(defaults: b)
        XCTAssertTrue(aText.contains("owner A previous session"))
        XCTAssertTrue(aText.contains("owner A current"))
        XCTAssertFalse(aText.contains("retired callback"))
        XCTAssertFalse(aText.contains("owner B"))
        XCTAssertTrue(bText.contains("owner B previous session"))
        XCTAssertTrue(bText.contains("owner B current"))
        XCTAssertFalse(bText.contains("owner A"))
        XCTAssertTrue(old.log.isEmpty)
        XCTAssertTrue(old.exportableLogText().isEmpty)
    }
}
