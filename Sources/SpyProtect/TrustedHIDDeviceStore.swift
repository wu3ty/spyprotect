import Foundation

struct TrustedHIDDevice: Codable, Identifiable, Equatable {
    var id: String { Self.key(vendorID: vendorID, productID: productID) }
    let vendorID: Int
    let productID: Int
    let name: String
    let firstSeenAt: Date

    static func key(vendorID: Int, productID: Int) -> String { "\(vendorID)-\(productID)" }
}

/// Devices seen presenting a HID-class USB interface while the screen was unlocked - i.e.
/// plugged in during normal, active use rather than appearing while locked. Matched by
/// vendor/product ID only (most HID devices don't expose a serial number), so this trusts
/// "any unit of this exact make/model", not one physical unit - enough to stop your own
/// keyboard/mouse/dongle re-enumerating (e.g. after sleep/wake) from re-triggering a
/// snapshot + alert, though a device deliberately cloning those IDs would also pass. See
/// USBWatcher's doc comment for the same caveat on the underlying HID-class signal.
final class TrustedHIDDeviceStore {
    static let shared = TrustedHIDDeviceStore()

    private let fileURL: URL

    private convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpyProtect", isDirectory: true)
        self.init(directory: dir)
    }

    /// Exposed (not just `private`) so tests can point at an isolated temp directory
    /// instead of the real Application Support path.
    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("trusted-hid-devices.json")
    }

    func isTrusted(vendorID: Int, productID: Int) -> Bool {
        let key = TrustedHIDDevice.key(vendorID: vendorID, productID: productID)
        return all().contains { $0.id == key }
    }

    /// Records a device as trusted the first time it's seen while unlocked. No-ops if
    /// already known, so `firstSeenAt` reflects when it was first plugged in, not the
    /// most recent reconnect.
    func trust(vendorID: Int, productID: Int, name: String) {
        let key = TrustedHIDDevice.key(vendorID: vendorID, productID: productID)
        var devices = all()
        guard !devices.contains(where: { $0.id == key }) else { return }
        devices.append(TrustedHIDDevice(vendorID: vendorID, productID: productID, name: name, firstSeenAt: Date()))
        save(devices)
    }

    /// Every trusted device, oldest first. Used to populate the "Trusted Devices" window.
    func all() -> [TrustedHIDDevice] {
        guard let data = try? Data(contentsOf: fileURL),
              let devices = try? JSONDecoder().decode([TrustedHIDDevice].self, from: data) else { return [] }
        return devices.sorted { $0.firstSeenAt < $1.firstSeenAt }
    }

    private func save(_ devices: [TrustedHIDDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
