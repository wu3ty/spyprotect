import XCTest
@testable import SpyProtect

final class TrustedPlaceTests: XCTestCase {
    private func makeStore() -> TrustedPlaceStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return TrustedPlaceStore(directory: dir)
    }

    func testTrustAndUntrust() {
        let store = makeStore()
        XCTAssertFalse(store.isTrusted(ssid: "Home"))
        store.trust(ssid: "Home")
        store.trust(ssid: "Home")
        XCTAssertTrue(store.isTrusted(ssid: "Home"))
        XCTAssertEqual(store.all().count, 1)
        store.untrust(ssid: "Home")
        XCTAssertFalse(store.isTrusted(ssid: "Home"))
    }

    func testServiceFailsTowardMonitoringWhenSSIDUnknown() {
        let store = makeStore()
        store.trust(ssid: "Home")
        XCTAssertFalse(TrustedPlaceService(store: store, currentSSID: { nil }).isInTrustedPlace)
        XCTAssertFalse(TrustedPlaceService(store: store, currentSSID: { "Cafe" }).isInTrustedPlace)
        XCTAssertTrue(TrustedPlaceService(store: store, currentSSID: { "Home" }).isInTrustedPlace)
    }

    func testNothingIsRecordedOrNotifiedWhileLockedInTrustedPlace() {
        var cameraCalls = 0, notifyCalls = 0
        let monitor = Monitor(
            cameraCapture: { cameraCalls += 1; $0(nil) },
            notify: { _, _ in notifyCalls += 1 },
            notifySessionSummary: { _ in },
            appendSession: { _ in XCTFail("nothing should be persisted at a trusted place") },
            scheduleAuthFailureRecheck: { $0() },
            isInTrustedPlace: { true })
        monitor.screenLocked()
        monitor.waitForQueueForTesting()
        monitor.handleAuthFailure(detail: "x")
        monitor.handleHIDDetected(deviceName: "kbd", vendorID: 1, productID: 2)
        monitor.handleUSBEvent(deviceName: "drive", inserted: true, vendorID: 3, productID: 4)
        monitor.handleAppLaunched(name: "Safari")
        monitor.handleLidStateChange(closed: true)
        monitor.screenUnlocked()
        monitor.waitForQueueForTesting()
        XCTAssertEqual(cameraCalls, 0)
        XCTAssertEqual(notifyCalls, 0)
    }
}
