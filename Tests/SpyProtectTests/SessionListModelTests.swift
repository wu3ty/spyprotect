import XCTest
@testable import SpyProtect

@MainActor
final class SessionListModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SpyProtectTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSession(lockedAt: Date) -> AwaySession {
        AwaySession(lockedAt: lockedAt, unlockedAt: lockedAt.addingTimeInterval(30), events: [
            AwayEvent(kind: .authFailure, timestamp: lockedAt, detail: "Failed unlock attempt")
        ])
    }

    func testFreshModelTreatsAnySessionAsNewAndUnseen() {
        let model = SessionListModel(defaults: defaults)
        let session = makeSession(lockedAt: Date())
        model.sessions = [session]

        XCTAssertTrue(model.isNew(session))
        XCTAssertTrue(model.hasUnseen)
        XCTAssertEqual(model.oldCount, 0)
    }

    func testClearBadgeStopsFlaggingUnseenButKeepsSessionNew() {
        let model = SessionListModel(defaults: defaults)
        let session = makeSession(lockedAt: Date())
        model.sessions = [session]

        model.clearBadge()

        XCTAssertFalse(model.hasUnseen, "badge should clear immediately")
        XCTAssertTrue(model.isNew(session), "categorization watermark must not move just from clearing the badge")
    }

    func testMarkSeenForCategorizationTagsExistingSessionsOld() {
        let model = SessionListModel(defaults: defaults)
        let session = makeSession(lockedAt: Date())
        model.sessions = [session]

        model.markSeenForCategorization()

        XCTAssertFalse(model.isNew(session))
        XCTAssertEqual(model.oldCount, 1)
    }

    func testPrependNotifiesUnseenChanged() {
        let model = SessionListModel(defaults: defaults)
        var observedValues: [Bool] = []
        model.onUnseenChanged = { observedValues.append($0) }

        model.prepend(makeSession(lockedAt: Date()))

        XCTAssertEqual(observedValues, [true])
    }

    func testWatermarksPersistAcrossModelInstancesViaSameDefaults() {
        let firstModel = SessionListModel(defaults: defaults)
        let session = makeSession(lockedAt: Date())
        firstModel.sessions = [session]
        firstModel.markSeenForCategorization()
        firstModel.clearBadge()

        // A new model instance reading the same UserDefaults suite (e.g. after an app
        // relaunch) should pick up where the previous one left off.
        let secondModel = SessionListModel(defaults: defaults)
        secondModel.sessions = [session]

        XCTAssertFalse(secondModel.isNew(session))
        XCTAssertFalse(secondModel.hasUnseen)
    }
}
