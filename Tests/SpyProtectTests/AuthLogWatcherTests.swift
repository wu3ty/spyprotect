import XCTest
@testable import SpyProtect

final class AuthLogWatcherTests: XCTestCase {
    func testDetectsTouchIDMatchLine() {
        let line: Substring = "2026-09-08 16:40:56.536 Df loginwindow[468:7993ad] [com.apple.loginwindow.logging:Standard] -[LWAuthServiceManager event:eventHints:reply:] | ======== SCREENLOCK ==== APEventTouchIDMatch ========="
        XCTAssertTrue(AuthLogWatcher.isTouchIDMatchLine(line))
    }

    func testDoesNotFlagUnrelatedLineAsTouchIDMatch() {
        let line: Substring = "2026-09-08 16:40:57.052 E  opendirectoryd[433:7a245c] [com.apple.opendirectoryd:auth] Authentication failed for <private>: ODErrorCredentialsInvalid"
        XCTAssertFalse(AuthLogWatcher.isTouchIDMatchLine(line))
    }

    func testClassifiesAsTouchIDWhenMatchWasRecent() {
        XCTAssertEqual(AuthLogWatcher.classify(recentTouchIDMatch: true), "Failed unlock attempt (Touch ID)")
    }

    func testClassifiesAsPasswordWhenNoRecentMatch() {
        XCTAssertEqual(AuthLogWatcher.classify(recentTouchIDMatch: false), "Failed unlock attempt (password)")
    }

    func testRecentTouchIDMatchWithinWindowCounts() {
        let last = Date(timeIntervalSinceReferenceDate: 1000)
        let now = last.addingTimeInterval(0.5)
        XCTAssertTrue(AuthLogWatcher.isRecentTouchIDMatch(lastMatch: last, now: now, window: 3))
    }

    func testRecentTouchIDMatchOutsideWindowDoesNotCount() {
        let last = Date(timeIntervalSinceReferenceDate: 1000)
        let now = last.addingTimeInterval(5)
        XCTAssertFalse(AuthLogWatcher.isRecentTouchIDMatch(lastMatch: last, now: now, window: 3))
    }

    func testNoTouchIDMatchAtAllDoesNotCount() {
        XCTAssertFalse(AuthLogWatcher.isRecentTouchIDMatch(lastMatch: nil, now: Date(), window: 3))
    }
}
