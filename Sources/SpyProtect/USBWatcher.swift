import Foundation
import IOKit
import IOKit.usb

/// Watches for USB device attach/detach using IOKit notifications, and separately flags
/// devices that register a HID (Human Interface Device) class interface - the class code
/// keyboards and mice use, and the one BadUSB/"Rubber Ducky"-style keystroke-injection
/// attacks impersonate to type at the lock screen without ever looking like a storage
/// device. Note this also matches legitimate keyboards/mice/trackpads plugged in via USB
/// (or a wireless receiver dongle) - it's a "worth a closer look" signal, not proof of an
/// attack.
final class USBWatcher {
    private let onEvent: (_ detail: String, _ inserted: Bool) -> Void
    private let onHIDDetected: (_ detail: String) -> Void

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private var hidAddedIterator: io_iterator_t = 0

    private static let hidInterfaceClass: UInt8 = 3

    init(onEvent: @escaping (_ detail: String, _ inserted: Bool) -> Void,
         onHIDDetected: @escaping (_ detail: String) -> Void) {
        self.onEvent = onEvent
        self.onHIDDetected = onHIDDetected
    }

    func start() {
        // kIOUSBDeviceClassName ("IOUSBDevice") is the legacy IOUSBFamily class and no
        // longer appears in the IORegistry on modern macOS (confirmed via `ioreg -p
        // IOUSB` - every attached device, including USB sticks, shows up as
        // "IOUSBHostDevice" under the new IOUSBHostFamily stack). Matching on the old
        // name silently matched nothing.
        guard let matching = IOServiceMatching("IOUSBHostDevice"),
              let hidMatching = IOServiceMatching("IOUSBHostInterface") else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, matching as CFDictionary,
            { refcon, iterator in USBWatcher.drain(iterator, refcon: refcon, inserted: true) },
            selfPtr, &addedIterator)
        // Priming call: IOServiceAddMatchingNotification arms the iterator with every
        // already-connected device (required so it doesn't miss anything, per Apple's
        // docs), but those aren't new attach events - just silently consume them so
        // startup doesn't report your mouse/keyboard/dock as "just connected".
        USBWatcher.drainSilently(addedIterator)

        IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, matching as CFDictionary,
            { refcon, iterator in USBWatcher.drain(iterator, refcon: refcon, inserted: false) },
            selfPtr, &removedIterator)
        USBWatcher.drainSilently(removedIterator)

        // Interfaces (as opposed to the top-level device) are where the real HID class
        // code lives for composite devices - most keyboards/mice enumerate as a generic
        // device plus one or more HID interfaces, not a HID-class device directly.
        IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, hidMatching as CFDictionary,
            { refcon, iterator in USBWatcher.drainHID(iterator, refcon: refcon) },
            selfPtr, &hidAddedIterator)
        USBWatcher.drainSilently(hidAddedIterator)
    }

    private static func drainSilently(_ iterator: io_iterator_t) {
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
    }

    private static func drain(_ iterator: io_iterator_t, refcon: UnsafeMutableRawPointer?, inserted: Bool) {
        guard let refcon else { return }
        let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
        var device = IOIteratorNext(iterator)
        while device != 0 {
            let name = watcher.describe(device)
            watcher.onEvent(name, inserted)
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
        }
    }

    private static func drainHID(_ iterator: io_iterator_t, refcon: UnsafeMutableRawPointer?) {
        guard let refcon else { return }
        let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
        var interface = IOIteratorNext(iterator)
        while interface != 0 {
            if watcher.interfaceClass(interface) == hidInterfaceClass {
                let name = watcher.describeParentDevice(of: interface) ?? "USB HID device"
                watcher.onHIDDetected(name)
            }
            IOObjectRelease(interface)
            interface = IOIteratorNext(iterator)
        }
    }

    private func describe(_ device: io_object_t) -> String {
        var nameBuf = [CChar](repeating: 0, count: 128)
        if IORegistryEntryGetName(device, &nameBuf) == KERN_SUCCESS {
            return String(cString: nameBuf)
        }
        return "USB device"
    }

    private func interfaceClass(_ interface: io_object_t) -> UInt8? {
        guard let ref = IORegistryEntryCreateCFProperty(interface, "bInterfaceClass" as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (ref.takeRetainedValue() as? NSNumber)?.uint8Value
    }

    private func describeParentDevice(of interface: io_object_t) -> String? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(interface, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        var nameBuf = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(parent, &nameBuf) == KERN_SUCCESS else { return nil }
        return String(cString: nameBuf)
    }
}
