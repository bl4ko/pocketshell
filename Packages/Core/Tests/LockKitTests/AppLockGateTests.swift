import LockKit
import XCTest

final class AppLockGateTests: XCTestCase {
    func testDisabledNeverLocks() {
        var gate = AppLockGate(enabled: false)
        gate.appLaunched()
        XCTAssertFalse(gate.isLocked)
        gate.appBackgrounded(at: Date(timeIntervalSince1970: 0))
        gate.appActivated(at: Date(timeIntervalSince1970: 10_000))
        XCTAssertFalse(gate.isLocked)
    }

    func testEnabledLocksOnLaunch() {
        var gate = AppLockGate(enabled: true)
        gate.appLaunched()
        XCTAssertTrue(gate.isLocked)
    }

    func testUnlockClearsLock() {
        var gate = AppLockGate(enabled: true)
        gate.appLaunched()
        gate.unlock()
        XCTAssertFalse(gate.isLocked)
    }

    func testActivateWithinGraceStaysUnlocked() {
        var gate = AppLockGate(enabled: true, gracePeriod: 60)
        gate.appLaunched()
        gate.unlock()
        gate.appBackgrounded(at: Date(timeIntervalSince1970: 100))
        gate.appActivated(at: Date(timeIntervalSince1970: 130))
        XCTAssertFalse(gate.isLocked)
    }

    func testActivateAfterGraceLocks() {
        var gate = AppLockGate(enabled: true, gracePeriod: 60)
        gate.appLaunched()
        gate.unlock()
        gate.appBackgrounded(at: Date(timeIntervalSince1970: 100))
        gate.appActivated(at: Date(timeIntervalSince1970: 161))
        XCTAssertTrue(gate.isLocked)
    }

    func testZeroGraceLocksImmediately() {
        var gate = AppLockGate(enabled: true)
        gate.appLaunched()
        gate.unlock()
        gate.appBackgrounded(at: Date(timeIntervalSince1970: 100))
        gate.appActivated(at: Date(timeIntervalSince1970: 100.5))
        XCTAssertTrue(gate.isLocked)
    }

    func testActivateWithoutBackgroundKeepsState() {
        var gate = AppLockGate(enabled: true)
        gate.appLaunched()
        gate.unlock()
        gate.appActivated(at: Date(timeIntervalSince1970: 500))
        XCTAssertFalse(gate.isLocked)
    }
}
