import Foundation
import AppKit
import IOKit
import IOKit.usb

/// Not in the public headers, but this is the standard, widely-used way for a process to
/// read the screen's current lock state on demand (as opposed to only being told about
/// future lock/unlock *transitions* via distributed notifications).
@_silgen_name("CGSessionCopyCurrentDictionary")
func CGSessionCopyCurrentDictionary() -> CFDictionary?

private func isScreenCurrentlyLocked() -> Bool {
    guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (info["CGSSessionScreenIsLocked"] as? Int ?? 0) != 0
}

/// Central coordinator: watchers append events here continuously (regardless of lock
/// state, since e.g. a USB device could be inserted right as the screen locks), and on
/// unlock we slice out everything that happened during the away window.
final class Monitor {
    static let shared = Monitor()

    private let queue = DispatchQueue(label: "spyprotect.monitor")
    private var buffer: [AwayEvent] = []
    private var lockedAt: Date?

    var onNewSession: ((AwaySession) -> Void)?

    private var usbWatcher: USBWatcher?
    private var authLogWatcher: AuthLogWatcher?

    private init() {}

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenLocked),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        usbWatcher = USBWatcher(
            onEvent: { [weak self] deviceName, inserted in
                let label = inserted ? "USB device connected: \(deviceName)" : "USB device disconnected: \(deviceName)"
                self?.record(kind: inserted ? .usbInserted : .usbRemoved, detail: label)
            },
            onHIDDetected: { [weak self] deviceName in
                // Same treatment as a failed unlock attempt - this is the class code
                // keystroke-injection USB attacks impersonate, so it's worth a snapshot
                // too. Note it also fires for legitimate keyboards/mice/dongles.
                CameraCapture.shared.capture { imagePath in
                    self?.record(kind: .usbHIDConnected,
                                 detail: "Keyboard/HID-class device connected: \(deviceName)",
                                 imagePath: imagePath)
                }
            }
        )
        usbWatcher?.start()

        authLogWatcher = AuthLogWatcher { [weak self] detail in
            // Snapshot whoever's at the keyboard right when a failed attempt is
            // detected. Capture runs async (camera warm-up + exposure settle), so the
            // event is recorded once the photo is ready (or immediately with no photo
            // if capture fails/is denied) rather than blocking detection on it.
            CameraCapture.shared.capture { imagePath in
                self?.record(kind: .authFailure, detail: detail, imagePath: imagePath)
            }
        }
        authLogWatcher?.start()

        // If we're (re)launching while the screen is already locked - e.g. after a
        // crash, a relaunch during development, or a login-item start that races the
        // lock - we'd otherwise never get the original screenIsLocked notification and
        // silently drop every event until the next full lock/unlock cycle. Anchoring to
        // "now" means we miss whatever happened between the real lock and this start,
        // but everything from here on is still captured.
        if isScreenCurrentlyLocked() {
            queue.async { self.lockedAt = Date() }
        }
    }

    private func record(kind: AwayEvent.Kind, detail: String, imagePath: String? = nil) {
        queue.async {
            let now = Date()
            self.buffer.append(AwayEvent(kind: kind, timestamp: now, detail: detail, imagePath: imagePath))
            DispatchQueue.main.async {
                NotificationManager.shared.notify(kind: kind, detail: detail)
            }
            if self.buffer.count > 2000 {
                self.buffer.removeFirst(self.buffer.count - 2000)
            }
        }
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        record(kind: .appLaunched, detail: app.localizedName ?? app.bundleIdentifier ?? "unknown app")
    }

    @objc private func screenLocked() {
        queue.async { self.lockedAt = Date() }
    }

    @objc private func screenUnlocked() {
        let unlockedAt = Date()
        queue.async {
            guard let lockedAt = self.lockedAt else { return }
            self.lockedAt = nil
            let windowEvents = self.buffer.filter { $0.timestamp >= lockedAt && $0.timestamp <= unlockedAt }
            guard !windowEvents.isEmpty else { return }
            let session = AwaySession(lockedAt: lockedAt, unlockedAt: unlockedAt, events: windowEvents)
            EventStore.shared.append(session)
            DispatchQueue.main.async {
                self.onNewSession?(session)
                NotificationManager.shared.notifySessionSummary(session)
            }
        }
    }
}
