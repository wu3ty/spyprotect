import XCTest
@testable import SpyProtect

/// Covers the trusted-HID-device allowlist: a device seen while unlocked should be
/// remembered, and a later reconnect of that same device while locked should be logged
/// without a snapshot/alert, while an unrecognized device while locked still gets the
/// full camera-capture treatment.
final class MonitorHIDTrustTests: XCTestCase {
    private func makeMonitor(
        cameraCapture: @escaping (@escaping (String?) -> Void) -> Void = { $0(nil) },
        notify: @escaping (AwayEvent.Kind, String) -> Void = { _, _ in },
        isHIDDeviceTrusted: @escaping (Int, Int) -> Bool = { _, _ in false },
        trustHIDDevice: @escaping (Int, Int, String) -> Void = { _, _, _ in }
    ) -> Monitor {
        Monitor(
            cameraCapture: cameraCapture,
            notify: notify,
            isHIDDeviceTrusted: isHIDDeviceTrusted,
            trustHIDDevice: trustHIDDevice
        )
    }

    func testDeviceSeenWhileUnlockedIsTrusted() {
        var trustedVendorID: Int?
        var trustedProductID: Int?
        var trustedName: String?
        let monitor = makeMonitor(trustHIDDevice: { vendorID, productID, name in
            trustedVendorID = vendorID
            trustedProductID = productID
            trustedName = name
        })

        // Never locked, so this is normal, active use.
        monitor.handleHIDDetected(deviceName: "Apple Keyboard", vendorID: 0x05AC, productID: 0x0250)
        monitor.waitForQueueForTesting()

        XCTAssertEqual(trustedVendorID, 0x05AC)
        XCTAssertEqual(trustedProductID, 0x0250)
        XCTAssertEqual(trustedName, "Apple Keyboard")
    }

    func testUnidentifiableDeviceWhileUnlockedIsNotTrusted() {
        var trustCallCount = 0
        let monitor = makeMonitor(trustHIDDevice: { _, _, _ in trustCallCount += 1 })

        monitor.handleHIDDetected(deviceName: "USB HID device", vendorID: nil, productID: nil)
        monitor.waitForQueueForTesting()

        XCTAssertEqual(trustCallCount, 0, "a device we can't identify by vendor/product ID can't be trusted")
    }

    func testTrustedDeviceReconnectingWhileLockedSkipsCameraAndStillLogs() {
        var cameraCallCount = 0
        var notifyCallCount = 0
        let monitor = makeMonitor(
            cameraCapture: { completion in
                cameraCallCount += 1
                completion(nil)
            },
            notify: { _, _ in notifyCallCount += 1 },
            isHIDDeviceTrusted: { vendorID, productID in vendorID == 0x05AC && productID == 0x0250 }
        )

        monitor.screenLocked()
        monitor.waitForQueueForTesting()

        monitor.handleHIDDetected(deviceName: "Apple Keyboard", vendorID: 0x05AC, productID: 0x0250)
        monitor.waitForQueueForTesting()

        XCTAssertEqual(cameraCallCount, 0, "a known device reconnecting shouldn't trigger a snapshot")
        XCTAssertEqual(notifyCallCount, 1, "it should still be logged/notified, just without a photo")
    }

    func testUnknownDeviceWhileLockedStillFiresCamera() {
        var cameraCallCount = 0
        let monitor = makeMonitor(
            cameraCapture: { completion in
                cameraCallCount += 1
                completion(nil)
            },
            isHIDDeviceTrusted: { _, _ in false }
        )

        monitor.screenLocked()
        monitor.waitForQueueForTesting()

        monitor.handleHIDDetected(deviceName: "Suspicious Device", vendorID: 0x1234, productID: 0x5678)
        monitor.waitForQueueForTesting()

        XCTAssertEqual(cameraCallCount, 1, "a device never seen while unlocked is still worth a snapshot")
    }
}
