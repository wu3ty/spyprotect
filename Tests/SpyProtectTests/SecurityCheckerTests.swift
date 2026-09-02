import XCTest
@testable import SpyProtect

final class SecurityCheckerTests: XCTestCase {
    func testFileVaultOnDetection() {
        XCTAssertTrue(SecurityChecker.isFileVaultOn("FileVault is On.\n"))
        XCTAssertFalse(SecurityChecker.isFileVaultOn("FileVault is Off.\n"))
        XCTAssertFalse(SecurityChecker.isFileVaultOn(""))
    }

    func testGuestAccountDetection() {
        XCTAssertTrue(SecurityChecker.isGuestEnabled(status: 0, output: "1\n"))
        XCTAssertFalse(SecurityChecker.isGuestEnabled(status: 0, output: "0\n"))
        // Missing key (defaults exits non-zero, empty output) means "off" by default.
        XCTAssertFalse(SecurityChecker.isGuestEnabled(status: 1, output: ""))
    }

    func testFirewallDetection() {
        XCTAssertTrue(SecurityChecker.isFirewallOn("Firewall is enabled. (State = 1)\n"))
        XCTAssertFalse(SecurityChecker.isFirewallOn("Firewall is disabled. (State = 0)\n"))
    }

    func testLaunchdServiceRunningDetection() {
        let runningOutput = """
        system/com.openssh.sshd = {
            active count = 1
            state = running
        }
        """
        let stoppedOutput = """
        system/com.openssh.sshd = {
            active count = 0
            state = not running
        }
        """
        XCTAssertTrue(SecurityChecker.isLaunchdServiceRunning(runningOutput))
        XCTAssertFalse(SecurityChecker.isLaunchdServiceRunning(stoppedOutput))
    }

    func testRunChecksReturnsOneResultPerCheck() {
        // Exercises the real (machine-dependent) check pipeline end-to-end - just
        // verifies it doesn't crash and returns a fully-populated, non-empty result for
        // every check, regardless of what this particular machine's settings are.
        let checks = SecurityChecker.runChecks()
        XCTAssertEqual(checks.count, 8)
        for check in checks {
            XCTAssertFalse(check.title.isEmpty)
            XCTAssertFalse(check.detail.isEmpty)
            XCTAssertFalse(check.hint.isEmpty)
        }
    }
}
