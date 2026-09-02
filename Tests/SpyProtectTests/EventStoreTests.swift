import XCTest
@testable import SpyProtect

final class EventStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: EventStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpyProtectTests-\(UUID().uuidString)", isDirectory: true)
        store = EventStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeSession(lockedAt: Date? = nil, events: [AwayEvent] = [], reviewed: Bool = false) -> AwaySession {
        let locked = lockedAt ?? Date(timeIntervalSinceReferenceDate: 1000)
        let unlocked = locked.addingTimeInterval(60)
        return AwaySession(lockedAt: locked, unlockedAt: unlocked, events: events, reviewed: reviewed)
    }

    func testAppendAndRecent() {
        let session = makeSession(events: [
            AwayEvent(kind: .authFailure, timestamp: Date(), detail: "Failed unlock attempt")
        ])
        store.append(session)

        let recent = store.recent()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.id, session.id)
        XCTAssertEqual(recent.first?.events.first?.kind, .authFailure)
    }

    func testRecentReturnsNewestFirst() {
        let first = makeSession()
        let second = makeSession()
        store.append(first)
        store.append(second)

        let recent = store.recent()
        XCTAssertEqual(recent.map(\.id), [second.id, first.id])
    }

    func testSessionDuration() {
        let session = makeSession()
        XCTAssertEqual(session.duration, 60, accuracy: 0.001)
    }

    func testImagePathRoundTrips() {
        let session = makeSession(events: [
            AwayEvent(kind: .authFailure, timestamp: Date(), detail: "Failed unlock attempt", imagePath: "/tmp/snapshot.jpg")
        ])
        store.append(session)

        XCTAssertEqual(store.recent().first?.events.first?.imagePath, "/tmp/snapshot.jpg")
    }

    func testMissingImagePathDecodesAsNil() {
        // Simulates a session written before `imagePath` existed on AwayEvent - the
        // field must decode to nil, not fail the whole record.
        let session = makeSession(events: [
            AwayEvent(kind: .usbInserted, timestamp: Date(), detail: "USB device connected: Test Drive")
        ])
        store.append(session)

        XCTAssertNil(store.recent().first?.events.first?.imagePath)
    }

    func testSetReviewedTogglesOnlyMatchingSession() {
        let a = makeSession()
        let b = makeSession()
        store.append(a)
        store.append(b)

        store.setReviewed(id: a.id, reviewed: true)

        let recent = store.recent()
        XCTAssertEqual(recent.first(where: { $0.id == a.id })?.reviewed, true)
        XCTAssertEqual(recent.first(where: { $0.id == b.id })?.reviewed, false)
    }

    func testClearAllRemovesEverySession() {
        store.append(makeSession())
        store.append(makeSession())
        XCTAssertEqual(store.recent().count, 2)

        store.clearAll()
        XCTAssertEqual(store.recent().count, 0)
    }

    func testPruneOlderThanRemovesOnlyOldSessionsAndReturnsTheirImagePaths() {
        let now = Date()
        let old = makeSession(
            lockedAt: now.addingTimeInterval(-31 * 86400),
            events: [AwayEvent(kind: .authFailure, timestamp: now, detail: "Failed unlock attempt", imagePath: "/tmp/old.jpg")]
        )
        let recentEnough = makeSession(lockedAt: now.addingTimeInterval(-29 * 86400))
        let fresh = makeSession(lockedAt: now)
        store.append(old)
        store.append(recentEnough)
        store.append(fresh)

        let removedImagePaths = store.pruneOlderThan(days: 30)

        XCTAssertEqual(removedImagePaths, ["/tmp/old.jpg"])
        let remainingIDs = Set(store.recent().map(\.id))
        XCTAssertEqual(remainingIDs, [recentEnough.id, fresh.id])
    }

    func testPruneOlderThanIsNoOpWhenNothingIsOld() {
        store.append(makeSession(lockedAt: Date()))
        XCTAssertTrue(store.pruneOlderThan(days: 30).isEmpty)
        XCTAssertEqual(store.recent().count, 1)
    }

    func testPruneOlderThanCanEmptyTheStoreEntirely() {
        store.append(makeSession(lockedAt: Date().addingTimeInterval(-60 * 86400)))
        store.pruneOlderThan(days: 30)
        XCTAssertEqual(store.recent().count, 0)
    }
}
