import Foundation
import IOKit
import IOKit.usb

/// Watches for USB device attach/detach using IOKit notifications.
final class USBWatcher {
    private let onEvent: (_ detail: String, _ inserted: Bool) -> Void
    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    init(onEvent: @escaping (_ detail: String, _ inserted: Bool) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        // kIOUSBDeviceClassName ("IOUSBDevice") is the legacy IOUSBFamily class and no
        // longer appears in the IORegistry on modern macOS (confirmed via `ioreg -p
        // IOUSB` - every attached device, including USB sticks, shows up as
        // "IOUSBHostDevice" under the new IOUSBHostFamily stack). Matching on the old
        // name silently matched nothing.
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return }
        let port = IONotificationPortCreate(kIOMainPortDefault)
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Matching dictionary is consumed once per call, so retain it for the second call.
        let addedMatch = matching as CFDictionary
        let removedMatch = matching as CFDictionary

        IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, addedMatch,
            { refcon, iterator in USBWatcher.drain(iterator, refcon: refcon, inserted: true) },
            selfPtr, &addedIterator)
        // Priming call: IOServiceAddMatchingNotification arms the iterator with every
        // already-connected device (required so it doesn't miss anything, per Apple's
        // docs), but those aren't new attach events - just silently consume them so
        // startup doesn't report your mouse/keyboard/dock as "just connected".
        USBWatcher.drainSilently(addedIterator)

        IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, removedMatch,
            { refcon, iterator in USBWatcher.drain(iterator, refcon: refcon, inserted: false) },
            selfPtr, &removedIterator)
        USBWatcher.drainSilently(removedIterator)
    }

    private static func drainSilently(_ iterator: io_iterator_t) {
        var device = IOIteratorNext(iterator)
        while device != 0 {
            IOObjectRelease(device)
            device = IOIteratorNext(iterator)
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

    private func describe(_ device: io_object_t) -> String {
        var nameBuf = [CChar](repeating: 0, count: 128)
        if IORegistryEntryGetName(device, &nameBuf) == KERN_SUCCESS {
            return String(cString: nameBuf)
        }
        return "USB device"
    }
}
