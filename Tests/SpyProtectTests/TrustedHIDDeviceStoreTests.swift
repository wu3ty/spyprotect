import XCTest
@testable import SpyProtect

final class TrustedHIDDeviceStoreTests: XCTestCase {
    private var tempDir: URL!
    private var store: TrustedHIDDeviceStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpyProtectTests-\(UUID().uuidString)", isDirectory: true)
        store = TrustedHIDDeviceStore(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testUnknownDeviceIsNotTrusted() {
        XCTAssertFalse(store.isTrusted(vendorID: 0x05AC, productID: 0x0250))
    }

    func testTrustedDeviceIsTrusted() {
        store.trust(vendorID: 0x05AC, productID: 0x0250, name: "Apple Keyboard")
        XCTAssertTrue(store.isTrusted(vendorID: 0x05AC, productID: 0x0250))
    }

    func testTrustDoesNotAffectDifferentVendorOrProductID() {
        store.trust(vendorID: 0x05AC, productID: 0x0250, name: "Apple Keyboard")
        XCTAssertFalse(store.isTrusted(vendorID: 0x05AC, productID: 0x0251))
        XCTAssertFalse(store.isTrusted(vendorID: 0x046D, productID: 0x0250))
    }

    func testTrustingTheSameDeviceTwiceKeepsFirstSeenAt() {
        store.trust(vendorID: 0x05AC, productID: 0x0250, name: "Apple Keyboard")
        let firstSeenAt = store.all().first?.firstSeenAt

        store.trust(vendorID: 0x05AC, productID: 0x0250, name: "Apple Keyboard")

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.firstSeenAt, firstSeenAt)
    }

    func testAllPersistsAcrossStoreInstances() {
        store.trust(vendorID: 0x05AC, productID: 0x0250, name: "Apple Keyboard")

        let reopened = TrustedHIDDeviceStore(directory: tempDir)
        XCTAssertTrue(reopened.isTrusted(vendorID: 0x05AC, productID: 0x0250))
        XCTAssertEqual(reopened.all().first?.name, "Apple Keyboard")
    }

    func testAllIsSortedOldestFirst() {
        store.trust(vendorID: 0x05AC, productID: 0x0250, name: "First")
        store.trust(vendorID: 0x046D, productID: 0xC52B, name: "Second")

        XCTAssertEqual(store.all().map(\.name), ["First", "Second"])
    }
}
