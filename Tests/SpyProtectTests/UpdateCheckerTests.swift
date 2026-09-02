import XCTest
@testable import SpyProtect

final class UpdateCheckerTests: XCTestCase {
    func testNewerVersionDetected() {
        XCTAssertTrue(UpdateChecker.isVersion("1.1.0", newerThan: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isVersion("2.0.0", newerThan: "1.9.9"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0", newerThan: "1.0.0"))
    }

    func testOlderVersionIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0", newerThan: "1.1.0"))
    }

    func testNumericComparisonNotLexicographic() {
        // A naive string comparison would say "1.2.0" > "1.10.0" - must not.
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2.0", newerThan: "1.10.0"))
    }

    func testMismatchedComponentCounts() {
        XCTAssertTrue(UpdateChecker.isVersion("1.1", newerThan: "1.0.9"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0", newerThan: "1.0.1"))
    }
}
