import SwiftUI
import AppKit

final class TrustedDevicesModel: ObservableObject {
    @Published var devices: [TrustedHIDDevice] = []
    @Published var isScanning = false

    /// Trusts any HID device currently connected but not yet known, then refreshes
    /// `devices` from disk - covers devices that were already plugged in before the app
    /// (or this login session) started, since the passive IOKit notification stream in
    /// USBWatcher only reports a "first match" once per interface's lifetime.
    func scanForNewDevices() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            for device in USBWatcher.scanCurrentlyConnectedHIDDevices() {
                guard let vendorID = device.vendorID, let productID = device.productID else { continue }
                TrustedHIDDeviceStore.shared.trust(vendorID: vendorID, productID: productID, name: device.name)
            }
            let devices = TrustedHIDDeviceStore.shared.all()
            DispatchQueue.main.async {
                self.devices = devices
                self.isScanning = false
            }
        }
    }
}

struct TrustedDevicesView: View {
    @ObservedObject var model: TrustedDevicesModel

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.isScanning {
                VStack {
                    Spacer()
                    ProgressView("Checking for devices…")
                        .padding()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.devices.isEmpty {
                VStack {
                    Spacer()
                    Text("No trusted devices yet. A keyboard, mouse, or other HID device is added here automatically the first time it's seen while the screen is unlocked.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.devices) { device in
                            TrustedDeviceRow(device: device, dateFormatter: Self.dateFormatter)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 420, idealHeight: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trusted Devices")
                .font(.title2).bold()
            Text("Keyboards, mice, and other HID devices seen while unlocked. These won't trigger a snapshot or alert if they reconnect while the screen is locked.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

struct TrustedDeviceRow: View {
    let device: TrustedHIDDevice
    let dateFormatter: DateFormatter

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "keyboard")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.body).bold()
                Text(String(format: "Vendor 0x%04X, Product 0x%04X", device.vendorID, device.productID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("First seen \(dateFormatter.string(from: device.firstSeenAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}
