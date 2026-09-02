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
        appendSession: @escaping (AwaySession) -> Void = { _ in }
    ) -> Monitor {
        Monitor(
            cameraCapture: cameraCapture,
            notify: notify,
            notifySessionSummary: notifySessionSummary,
            appendSession: appendSession
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
        monitor.waitForQueueForTesting()

        monitor.screenUnlocked()
        wait(for: [sessionExpectation], timeout: 1.0)

        XCTAssertEqual(cameraCallCount, 2, "authFailure and HID detection should each capture a photo")
        XCTAssertEqual(notifyCallCount, 3, "all three detections should have notified")
        XCTAssertEqual(appendedSession?.events.count, 3)
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
