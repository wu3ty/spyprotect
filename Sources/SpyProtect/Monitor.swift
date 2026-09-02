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

/// Central coordinator: watchers report raw detections continuously, but every one of
/// them is gated on `isCurrentlyLocked` before it's allowed to touch the camera, fire a
/// notification, or even be buffered - detecting something (a log line, a USB event) is
/// not the same as the screen actually being locked, and only the latter should ever be
/// visible or have a side effect. On unlock we slice the buffer down to the away window.
///
/// Camera capture, notifications, session persistence, and the trusted-HID-device store
/// are all injectable (defaulting to the real singletons) so tests can exercise the
/// actual detector entry points -
/// handleUSBEvent, handleHIDDetected, handleAuthFailure, handleAppLaunched - with spies,
/// instead of only being able to review the lock-state gating by eye.
final class Monitor {
    static let shared = Monitor()

    private let queue = DispatchQueue(label: "spyprotect.monitor")
    private var buffer: [AwayEvent] = []
    private var lockedAt: Date?

    var onNewSession: ((AwaySession) -> Void)?

    private var usbWatcher: USBWatcher?
    private var authLogWatcher: AuthLogWatcher?
    private var retentionTimer: Timer?

    private let cameraCapture: (@escaping (String?) -> Void) -> Void
    private let notify: (AwayEvent.Kind, String) -> Void
    private let notifySessionSummary: (AwaySession) -> Void
    private let appendSession: (AwaySession) -> Void
    private let isHIDDeviceTrusted: (_ vendorID: Int, _ productID: Int) -> Bool
    private let trustHIDDevice: (_ vendorID: Int, _ productID: Int, _ name: String) -> Void

    /// Sessions and their snapshot photos older than this are auto-deleted (documented
    /// in README under Privacy notes).
    static let retentionDays = 30

    init(
        cameraCapture: @escaping (@escaping (String?) -> Void) -> Void = { CameraCapture.shared.capture(completion: $0) },
        notify: @escaping (AwayEvent.Kind, String) -> Void = { NotificationManager.shared.notify(kind: $0, detail: $1) },
        notifySessionSummary: @escaping (AwaySession) -> Void = { NotificationManager.shared.notifySessionSummary($0) },
        appendSession: @escaping (AwaySession) -> Void = { EventStore.shared.append($0) },
        isHIDDeviceTrusted: @escaping (_ vendorID: Int, _ productID: Int) -> Bool = {
            TrustedHIDDeviceStore.shared.isTrusted(vendorID: $0, productID: $1)
        },
        trustHIDDevice: @escaping (_ vendorID: Int, _ productID: Int, _ name: String) -> Void = {
            TrustedHIDDeviceStore.shared.trust(vendorID: $0, productID: $1, name: $2)
        }
    ) {
        self.cameraCapture = cameraCapture
        self.notify = notify
        self.notifySessionSummary = notifySessionSummary
        self.appendSession = appendSession
        self.isHIDDeviceTrusted = isHIDDeviceTrusted
        self.trustHIDDevice = trustHIDDevice
    }

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
                self?.handleUSBEvent(deviceName: deviceName, inserted: inserted)
            },
            onHIDDetected: { [weak self] deviceName, vendorID, productID in
                self?.handleHIDDetected(deviceName: deviceName, vendorID: vendorID, productID: productID)
            }
        )
        usbWatcher?.start()

        authLogWatcher = AuthLogWatcher { [weak self] detail in
            self?.handleAuthFailure(detail: detail)
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

        pruneOldData()
        // Also re-run daily in case the app stays running for a long stretch without a
        // relaunch (e.g. as a login item that's never quit) - otherwise pruning would
        // only ever happen once, at whatever moment the app happened to start.
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            self?.pruneOldData()
        }
    }

    // MARK: - Detector entry points
    //
    // Each of these is the single gate its detector must pass through: check
    // isCurrentlyLocked FIRST, before touching the camera or firing anything. Exposed
    // (not private) so tests can call them directly with fake camera/notify/append
    // closures, verifying the actual gating behavior rather than just reading the code.

    func handleUSBEvent(deviceName: String, inserted: Bool) {
        guard isCurrentlyLocked else { return }
        let label = inserted ? "USB device connected: \(deviceName)" : "USB device disconnected: \(deviceName)"
        record(kind: inserted ? .usbInserted : .usbRemoved, detail: label)
    }

    func handleHIDDetected(deviceName: String, vendorID: Int? = nil, productID: Int? = nil) {
        // This fires on any HID-class USB interface appearing (keyboards, mice,
        // dongles) regardless of what's happening on screen, and must never take a
        // photo or notify during normal, unlocked use.
        guard isCurrentlyLocked else {
            // Seeing this device while unlocked - i.e. during normal, active use, not
            // appearing out of nowhere while away - is exactly what makes it trustworthy.
            // Remember it so a later reconnect while locked (e.g. the same keyboard
            // re-enumerating after sleep/wake) doesn't retrigger a snapshot + alert.
            if let vendorID, let productID {
                trustHIDDevice(vendorID, productID, deviceName)
            }
            return
        }
        if let vendorID, let productID, isHIDDeviceTrusted(vendorID, productID) {
            record(kind: .usbHIDConnected, detail: "Known keyboard/HID-class device reconnected: \(deviceName)")
            return
        }
        // Same treatment as a failed unlock attempt - this is the class code
        // keystroke-injection USB attacks impersonate, so it's worth a snapshot too.
        // Note it also fires for legitimate keyboards/mice/dongles never seen while
        // unlocked before (e.g. the very first time this app runs).
        cameraCapture { [weak self] imagePath in
            self?.record(kind: .usbHIDConnected,
                          detail: "Keyboard/HID-class device connected: \(deviceName)",
                          imagePath: imagePath)
        }
    }

    func handleAuthFailure(detail: String) {
        // The log predicate is a heuristic on system log phrasing - it can also match a
        // local authentication prompt (Touch ID, a password manager, signing into a
        // website with a passkey) that happens while the Mac is unlocked and in active,
        // normal use. Never take a photo or notify unless we're actually in a confirmed
        // locked/away window.
        guard isCurrentlyLocked else { return }
        // Snapshot whoever's at the keyboard right when a failed attempt is detected.
        // Capture runs async (camera warm-up + exposure settle), so the event is
        // recorded once the photo is ready (or immediately with no photo if capture
        // fails/is denied) rather than blocking detection on it.
        cameraCapture { [weak self] imagePath in
            self?.record(kind: .authFailure, detail: detail, imagePath: imagePath)
        }
    }

    func handleAppLaunched(name: String) {
        guard isCurrentlyLocked else { return }
        record(kind: .appLaunched, detail: name)
    }

    /// Thread-safe read of whether we're currently in a locked/away window - the single
    /// gate every detector must pass before touching the camera, firing a notification,
    /// or even bothering to record anything. Detecting something is not the same as
    /// being locked; only the latter should ever have a visible side effect.
    private var isCurrentlyLocked: Bool {
        queue.sync { lockedAt != nil }
    }

    private func pruneOldData() {
        let removedImagePaths = EventStore.shared.pruneOlderThan(days: Self.retentionDays)
        if !removedImagePaths.isEmpty {
            CameraCapture.shared.deletePhotos(atPaths: removedImagePaths)
        }
    }

    private func record(kind: AwayEvent.Kind, detail: String, imagePath: String? = nil) {
        queue.async {
            let now = Date()
            self.buffer.append(AwayEvent(kind: kind, timestamp: now, detail: detail, imagePath: imagePath))
            self.notify(kind, detail)
            if self.buffer.count > 2000 {
                self.buffer.removeFirst(self.buffer.count - 2000)
            }
        }
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        handleAppLaunched(name: app.localizedName ?? app.bundleIdentifier ?? "unknown app")
    }

    @objc func screenLocked() {
        queue.async { self.lockedAt = Date() }
    }

    @objc func screenUnlocked() {
        let unlockedAt = Date()
        queue.async {
            guard let lockedAt = self.lockedAt else { return }
            self.lockedAt = nil
            let windowEvents = self.buffer.filter { $0.timestamp >= lockedAt && $0.timestamp <= unlockedAt }
            guard !windowEvents.isEmpty else { return }
            let session = AwaySession(lockedAt: lockedAt, unlockedAt: unlockedAt, events: windowEvents)
            self.appendSession(session)
            DispatchQueue.main.async {
                self.onNewSession?(session)
                self.notifySessionSummary(session)
            }
        }
    }

    /// Test-only: blocks until every block already queued on `queue` (buffer
    /// mutations, lock-state changes) has finished running, so assertions made right
    /// after calling a handler method see up-to-date state instead of racing it.
    func waitForQueueForTesting() {
        queue.sync {}
    }
}
