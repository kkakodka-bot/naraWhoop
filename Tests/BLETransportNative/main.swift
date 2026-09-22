import Darwin
import XCTest

let suite = XCTestSuite(name: "Production BLE transport driver with scripted central and peripherals")
suite.addTest(BLETransportDriverTests.defaultTestSuite)
suite.addTest(BLENotificationControllerTests.defaultTestSuite)
suite.run()
guard let result = suite.testRun else { exit(2) }
print("BLETransportNative: executed=\(result.executionCount) failures=\(result.totalFailureCount) skipped=\(result.skipCount)")
guard result.executionCount == 36, result.skipCount == 0 else { exit(2) }
exit(result.hasSucceeded ? 0 : 1)
