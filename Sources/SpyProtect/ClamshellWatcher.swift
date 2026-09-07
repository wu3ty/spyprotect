import Foundation
import IOKit
import IOKit.pwr_mgt

/// Watches the lid open/closed state ("clamshell state") via IOPMrootDomain, the same
/// IORegistry entry `pmset`/`ioreg` read it from. There's no public accelerometer/motion
/// API on the Mac to detect the machine being physically picked up (older spinning-disk
/// MacBooks exposed a "Sudden Motion Sensor" for head-parking; it was dropped once Macs
/// went all-flash, and Apple Silicon Macs have no equivalent public API) - lid state is
/// the closest thing that's actually supported: someone opening a locked, closed laptop
/// is exactly the "was it handled while I was away" signal being approximated here.
final class ClamshellWatcher {
    private let onChange: (_ closed: Bool) -> Void
    private var timer: Timer?
    private var lastState: Bool?

    /// How often to poll. The lock screen itself doesn't need finer resolution than this,
    /// and polling (vs. an IOKit interest notification) keeps this watcher simple and
    /// dependency-free.
    private static let pollInterval: TimeInterval = 1.0

    init(onChange: @escaping (_ closed: Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        // Establish a baseline silently - like USBWatcher's priming drain, the current
        // state at launch isn't a "change" and shouldn't be reported as one.
        lastState = Self.currentClamshellState()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let state = Self.currentClamshellState(), state != lastState else { return }
        lastState = state
        onChange(state)
    }

    /// true = closed, false = open, nil = couldn't be read (e.g. a desktop Mac with no lid).
    private static func currentClamshellState() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let ref = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        return (ref.takeRetainedValue() as? NSNumber)?.boolValue
    }
}
