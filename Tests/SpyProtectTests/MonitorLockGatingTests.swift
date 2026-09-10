import XCTest
@testable import SpyProtect

/// Regression coverage for a real bug: every detector used to fire its camera/
/// notification side effects the instant something was detected, with no check that the
/// screen was actually locked - so a Touch ID/passkey prompt during normal, unlocked use
/// could trigger a camera capture and a notification. These tests drive the actual
/// detector entry points (handleUSBEvent, handleHIDDetected, handleAuthFailure,
/// handleAppLaunched) with spies standing in for the camera/notification/persistence
/// dependencies, so a future change that reintroduces this bug fails CI instead of
/// waiting to be noticed live.
final class MonitorLockGatingTests: XCTestCase {
    private func makeMonitor(
        cameraCapture: @escaping (@escaping (String?) -> Void) -> Void = { $0(nil) },
        notify: @escaping (AwayEvent.Kind, String) -> Void = { _, _ in },
        notifySessionSummary: @escaping (AwaySession) -> Void = { _ in },
        appendSession: @escaping (AwaySession) -> Void = { _ in },
        // Real Monitor waits authFailureGracePeriod before rechecking lock state (see
        // its doc comment) - tests don't want to actually wait 3 real seconds, so unless
        // a test overrides this to inspect the debounce itself, run the check inline.
        scheduleAuthFailureRecheck: @escaping (@escaping () -> Void) -> Void = { $0() }
    ) -> Monitor {
        Monitor(
            cameraCapture: cameraCapture,
            notify: notify,
            notifySessionSummary: notifySessionSummary,
            appendSession: appendSession,
            scheduleAuthFailureRecheck: scheduleAuthFailureRecheck
        )
    }

    func testNoDetectorFiresCameraOrNotificationWhileUnlocked() {
        var cameraCallCount = 0
        var notifyCallCount = 0
        let monitor = makeMonitor(
            cameraCapture: { completion in
                cameraCallCount += 1
                completion(nil)
            },
            notify: { _, _ in notifyCallCount += 1 },
            appendSession: { _ in XCTFail("a session should never be persisted without ever having been locked") }
        )

        // The screen was never locked - lockedAt stays nil for the lifetime of this
        // monitor - so none of these should do anything at all.
        monitor.handleAuthFailure(detail: "Failed unlock attempt")
        monitor.handleHIDDetected(deviceName: "Test Keyboard")
        monitor.handleUSBEvent(deviceName: "Test Drive", inserted: true)
        monitor.handleAppLaunched(name: "Safari")
        monitor.handleLidStateChange(closed: false)
        monitor.waitForQueueForTesting()

        XCTAssertEqual(cameraCallCount, 0, "camera must never be touched while unlocked")
        XCTAssertEqual(notifyCallCount, 0, "no notification should fire while unlocked")
    }

    func testDetectionsWhileLockedFireSideEffectsAndPersistOnUnlock() {
        var cameraCallCount = 0
        var notifyCallCount = 0
        var appendedSession: AwaySession?
        let sessionExpectation = expectation(description: "session persisted and delivered")

        let monitor = makeMonitor(
            cameraCapture: { completion in
                cameraCallCount += 1
                completion("/tmp/fake-snapshot.jpg")
            },
            notify: { _, _ in notifyCallCount += 1 },
            appendSession: { session in appendedSession = session }
        )
        monitor.onNewSession = { _ in sessionExpectation.fulfill() }

        monitor.screenLocked()
        monitor.waitForQueueForTesting()

        monitor.handleAuthFailure(detail: "Failed unlock attempt")
        monitor.handleHIDDetected(deviceName: "Test Keyboard")
        monitor.handleUSBEvent(deviceName: "Test Drive", inserted: true)
        monitor.handleLidStateChange(closed: false)
        monitor.waitForQueueForTesting()

        monitor.screenUnlocked()
        wait(for: [sessionExpectation], timeout: 1.0)

        XCTAssertEqual(cameraCallCount, 2, "authFailure and HID detection should each capture a photo")
        XCTAssertEqual(notifyCallCount, 4, "all four detections should have notified")
        XCTAssertEqual(appendedSession?.events.count, 4)
        XCTAssertEqual(appendedSession?.events.compactMap(\.imagePath).count, 2, "only the two camera-backed events should carry a snapshot path")
    }

    func testDetectionAfterUnlockDoesNotFireAgain() {
        var cameraCallCount = 0
        let monitor = makeMonitor(cameraCapture: { completion in
            cameraCallCount += 1
            completion(nil)
        })

        monitor.screenLocked()
        monitor.waitForQueueForTesting()
        monitor.screenUnlocked()
        monitor.waitForQueueForTesting()

        // Back to normal, unlocked use - must behave exactly like "never locked".
        monitor.handleAuthFailure(detail: "Failed unlock attempt")
        monitor.waitForQueueForTesting()

        XCTAssertEqual(cameraCallCount, 0)
    }

    /// A composite device (a trackpad, a keyboard with a built-in hub) enumerates several
    /// separate HID-class interfaces at once, each of which independently calls
    /// handleHIDDetected with the same vendor/product ID - this reproduces that and
    /// asserts only one event/notification/photo results, not one per interface.
    func testRepeatedHIDInterfacesFromSameDeviceOnlyRecordOnce() {
        var cameraCallCount = 0
        var notifyCallCount = 0
        var appendedSession: AwaySession?
        let sessionExpectation = expectation(description: "session persisted")

        let monitor = makeMonitor(
            cameraCapture: { completion in
                cameraCallCount += 1
                completion(nil)
            },
            notify: { _, _ in notifyCallCount += 1 },
            appendSession: { session in appendedSession = session }
        )
        monitor.onNewSession = { _ in sessionExpectation.fulfill() }

        monitor.screenLocked()
        monitor.waitForQueueForTesting()

        // Four interfaces of the same physical Magic Trackpad, as actually observed.
        // No vendor/product ID, same as the other tests in this file - keeps this test
        // from touching the real, disk-backed TrustedHIDDeviceStore.shared singleton;
        // the dedupe falls back to keying on the device name in that case.
        for _ in 0..<4 {
            monitor.handleHIDDetected(deviceName: "Magic Trackpad")
        }
        monitor.waitForQueueForTesting()

        monitor.screenUnlocked()
        wait(for: [sessionExpectation], timeout: 1.0)

        XCTAssertEqual(cameraCallCount, 1)
        XCTAssertEqual(notifyCallCount, 1)
        XCTAssertEqual(appendedSession?.events.count, 1)
    }

    /// A genuine reconnect in a later lock session (not just another interface of the
    /// same still-open session) must still be reported - the dedupe is scoped per
    /// session, not permanent.
    func testSameDeviceIsReportedAgainInANewLockSession() {
        var notifyCallCount = 0
        let monitor = makeMonitor(notify: { _, _ in notifyCallCount += 1 })

        monitor.screenLocked()
        monitor.waitForQueueForTesting()
        monitor.handleHIDDetected(deviceName: "Magic Trackpad")
        monitor.waitForQueueForTesting()
        monitor.screenUnlocked()
        monitor.waitForQueueForTesting()

        monitor.screenLocked()
        monitor.waitForQueueForTesting()
        monitor.handleHIDDetected(deviceName: "Magic Trackpad")
        monitor.waitForQueueForTesting()

        XCTAssertEqual(notifyCallCount, 2, "each lock session should get its own reconnect notification")
    }

    /// opendirectoryd logs its "Authentication failed" line as routine noise on
    /// essentially every unlock, correct credential or not (see Monitor's
    /// authFailureGracePeriod doc comment). A genuine failure leaves the screen locked;
    /// this reproduces the noise case - unlock happens before the grace-period recheck
    /// fires - and asserts it's discarded rather than recorded/notified.
    func testAuthFailureIsDiscardedWhenUnlockFollowsBeforeGracePeriodElapses() {
        var cameraCallCount = 0
        var notifyCallCount = 0
        var recheckBlock: (() -> Void)?

        let monitor = makeMonitor(
            cameraCapture: { completion in
                cameraCallCount += 1
                completion(nil)
            },
            notify: { _, _ in notifyCallCount += 1 },
            appendSession: { _ in XCTFail("the noise event shouldn't produce a session") },
            scheduleAuthFailureRecheck: { block in recheckBlock = block }
        )

        monitor.screenLocked()
        monitor.waitForQueueForTesting()

        monitor.handleAuthFailure(detail: "Failed unlock attempt")
        monitor.waitForQueueForTesting()
        XCTAssertNotNil(recheckBlock, "the recheck should have been scheduled, not run inline")

        // The real unlock happens - e.g. the correct Touch ID match - before the grace
        // period's recheck fires.
        monitor.screenUnlocked()
        monitor.waitForQueueForTesting()

        recheckBlock?()
        monitor.waitForQueueForTesting()

        XCTAssertEqual(cameraCallCount, 0, "no snapshot should be taken for noise that turned out to be a successful unlock")
        XCTAssertEqual(notifyCallCount, 0, "no notification should fire for it either")
    }

    /// The mirror image of the above: the screen is still locked when the grace period's
    /// recheck fires, so this was a genuine failed attempt and must still go through.
    func testAuthFailureStillFiresWhenScreenRemainsLockedThroughGracePeriod() {
        var cameraCallCount = 0
        var notifyCallCount = 0
        var recheckBlock: (() -> Void)?

        let monitor = makeMonitor(
            cameraCapture: { completion in
                cameraCallCount += 1
                completion(nil)
            },
            notify: { _, _ in notifyCallCount += 1 },
            scheduleAuthFailureRecheck: { block in recheckBlock = block }
        )

        monitor.screenLocked()
        monitor.waitForQueueForTesting()

        monitor.handleAuthFailure(detail: "Failed unlock attempt")
        monitor.waitForQueueForTesting()

        // Still locked - nobody unlocked in the meantime - so the grace period's recheck
        // should let it through.
        recheckBlock?()
        monitor.waitForQueueForTesting()

        XCTAssertEqual(cameraCallCount, 1)
        XCTAssertEqual(notifyCallCount, 1)
    }

    func testAppendSessionIsNotCalledWhenNoEventsOccurredWhileLocked() {
        var appendCallCount = 0
        let monitor = makeMonitor(appendSession: { _ in appendCallCount += 1 })

        monitor.screenLocked()
        monitor.waitForQueueForTesting()
        monitor.screenUnlocked()
        monitor.waitForQueueForTesting()

        XCTAssertEqual(appendCallCount, 0, "an empty away session shouldn't be persisted")
    }
}
