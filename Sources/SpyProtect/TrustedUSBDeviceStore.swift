import Foundation

struct TrustedUSBDevice: Codable, Identifiable, Equatable {
    var id: String { Self.key(vendorID: vendorID, productID: productID) }
    let vendorID: Int
    let productID: Int
    let name: String
    let firstSeenAt: Date

    static func key(vendorID: Int, productID: Int) -> String { "\(vendorID)-\(productID)" }
}

/// Any USB device (hub, dock, trackpad, storage, ...) seen attached while the screen was
/// unlocked - i.e. plugged in during normal, active use rather than appearing while locked.
/// Sleep/wake and lock/unlock typically power-cycle an entire USB hub tree at once (a dock,
/// its built-in hub, and everything plugged into it all disconnect and reconnect together),
/// so without this, every lock event re-logs and re-notifies for the same handful of
/// permanently-attached peripherals. Matched by vendor/product ID only, same caveat as
/// TrustedHIDDeviceStore: this trusts "any unit of this exact make/model", not one physical
/// unit.
final class TrustedUSBDeviceStore {
    static let shared = TrustedUSBDeviceStore()

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
        fileURL = directory.appendingPathComponent("trusted-usb-devices.json")
    }

    func isTrusted(vendorID: Int, productID: Int) -> Bool {
        let key = TrustedUSBDevice.key(vendorID: vendorID, productID: productID)
        return all().contains { $0.id == key }
    }

    /// Records a device as trusted the first time it's seen while unlocked. No-ops if
    /// already known, so `firstSeenAt` reflects when it was first plugged in, not the
    /// most recent reconnect.
    func trust(vendorID: Int, productID: Int, name: String) {
        let key = TrustedUSBDevice.key(vendorID: vendorID, productID: productID)
        var devices = all()
        guard !devices.contains(where: { $0.id == key }) else { return }
        devices.append(TrustedUSBDevice(vendorID: vendorID, productID: productID, name: name, firstSeenAt: Date()))
        save(devices)
    }

    /// Every trusted device, oldest first.
    func all() -> [TrustedUSBDevice] {
        guard let data = try? Data(contentsOf: fileURL),
              let devices = try? JSONDecoder().decode([TrustedUSBDevice].self, from: data) else { return [] }
        return devices.sorted { $0.firstSeenAt < $1.firstSeenAt }
    }

    private func save(_ devices: [TrustedUSBDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
