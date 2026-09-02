import SwiftUI
import AppKit

@main
struct SpyProtectApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var model = SessionListModel()
    private var securityCheckWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var updateCheckTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.isOnlyInstance() else {
            // Launched again (e.g. double-clicked in Finder) while already running as a
            // login item - quit immediately rather than spawning a second menu bar icon
            // and a second Monitor racing the first over the same log file.
            NSLog("SpyProtect: another instance is already running - exiting.")
            exit(0)
        }

        showWelcomeIfNeeded()

        model.reload()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.menuIcon
            button.action = #selector(handleClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 440, height: 520)
        pop.contentViewController = NSHostingController(rootView: SessionListView(model: model))
        pop.delegate = self
        popover = pop

        model.onUnseenChanged = { [weak self] hasUnseen in
            self?.updateIcon(hasUnseen: hasUnseen)
        }

        Monitor.shared.onNewSession = { [weak self] session in
            self?.model.prepend(session)
        }
        NotificationManager.shared.requestAuthorization()
        NotificationManager.shared.notifyStartupCheck()
        CameraCapture.shared.requestAccessIfNeeded()
        Monitor.shared.start()
        updateIcon(hasUnseen: model.hasUnseen)

        promptForLoginItemIfNeeded()
        scheduleAutoUpdateCheckIfNeeded()
    }

    /// True unless another process with the same bundle identifier is already running.
    private static func isOnlyInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID }
        return others.isEmpty
    }

    private static let hasShownWelcomeKey = "SpyProtect.hasShownWelcome"

    /// Shown once, before anything else (permission prompts, the login-item prompt,
    /// even starting the monitor) - macOS's Camera/Notification dialogs are a lot less
    /// jarring for someone downloading this cold if they've just been told, in plain
    /// language, why the app wants them and what it actually watches for.
    private func showWelcomeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.hasShownWelcomeKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.hasShownWelcomeKey)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Welcome to SpyProtect"
        alert.informativeText = """
            SpyProtect watches for activity while your screen is locked, so you know if anyone tried to get in while you were away.

            It logs:
            • Failed unlock attempts (with a webcam snapshot of whoever tried)
            • USB devices connecting or disconnecting, with keyboard/HID-class devices flagged separately
            • Apps launched while the screen was locked

            Nothing is logged while you're actively using the machine - only during the actual locked window. Everything stays on this computer; nothing is sent anywhere.

            Next, macOS will ask for Notification and Camera permission - both are needed for the features above.
            """
        alert.addButton(withTitle: "Get Started")
        alert.runModal()
    }

    private static let hasPromptedLoginItemKey = "SpyProtect.hasPromptedLoginItem"

    /// Asks once, the very first time the app runs, whether it should launch
    /// automatically at login/reboot - since a security-monitoring tool that has to be
    /// remembered and started by hand isn't actually watching anything most of the time.
    private func promptForLoginItemIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.hasPromptedLoginItemKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.hasPromptedLoginItemKey)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Start SpyProtect automatically?"
        alert.informativeText = "SpyProtect can launch every time you log in or restart, so it's always watching without you having to remember to start it yourself. You can change this later from the menu."
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            LoginItemManager.setEnabled(true)
        }
    }

    private func updateIcon(hasUnseen: Bool) {
        guard let button = statusItem?.button else { return }
        button.image = hasUnseen ? Self.menuIconAlert : Self.menuIcon
        button.image?.accessibilityDescription = hasUnseen ? "New activity" : "SpyProtect"
    }

    /// The plain eye glyph, marked as a template image so AppKit auto-tints it for
    /// light/dark menu bars and the highlighted/selected state - same as an SF Symbol.
    private static let menuIcon: NSImage? = {
        let image = Bundle.main.image(forResource: "MenuIcon")
        image?.isTemplate = true
        return image
    }()

    /// The alert variant has a fixed-color red dot baked in, so it's deliberately NOT a
    /// template image - the red needs to stay red regardless of menu bar appearance,
    /// at the cost of the eye shape itself not auto-inverting for dark menu bars.
    private static let menuIconAlert: NSImage? = Bundle.main.image(forResource: "MenuIconAlert")

    /// The full-color shield-and-eye logo (as opposed to the monochrome status bar
    /// glyph above) - used for branding in the right-click menu header and the popover
    /// title, sized down for a menu row.
    private static let logoIcon: NSImage? = {
        let image = Bundle.main.image(forResource: "AppLogoSmall")
        image?.size = NSSize(width: 18, height: 18)
        return image
    }()

    @objc private func handleClick(_ sender: AnyObject) {
        guard let button = statusItem?.button else { return }
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            let menu = buildStatusMenu()
            statusItem?.menu = menu
            button.performClick(nil)
            statusItem?.menu = nil
        } else {
            togglePopover(button)
        }
    }

    /// Rebuilt fresh on every right-click so the unseen-activity summary at the top is
    /// never stale - critical events need to be visible the moment you check, not just
    /// via the badge on the icon itself.
    private func buildStatusMenu() -> NSMenu {
        model.reload()
        let menu = NSMenu()

        let header = NSMenuItem(title: "SpyProtect", action: nil, keyEquivalent: "")
        header.image = Self.logoIcon
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let unseenCount = model.sessions.filter { model.isNew($0) }.count
        if unseenCount > 0 {
            let summary = NSMenuItem(title: "⚠️ \(unseenCount) new away session(s) with activity", action: nil, keyEquivalent: "")
            summary.isEnabled = false
            menu.addItem(summary)
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Run Security Check…", action: #selector(openSecurityCheck), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Export Log as PDF…", action: #selector(exportLogAsPDF), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear All Logs", action: #selector(clearAllLogs), keyEquivalent: ""))
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = LoginItemManager.isEnabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesManually), keyEquivalent: ""))
        let autoUpdateItem = NSMenuItem(title: "Automatically Check for Updates", action: #selector(toggleAutoUpdateCheck), keyEquivalent: "")
        autoUpdateItem.state = Self.autoCheckForUpdatesEnabled ? .on : .off
        menu.addItem(autoUpdateItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "About SpyProtect", action: #selector(openAbout), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SpyProtect", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        return menu
    }

    private func togglePopover(_ button: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(button)
        } else {
            model.reload()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            model.clearBadge()
        }
    }

    /// Covers every way the popover can close - explicit toggle-click, or the .transient
    /// auto-dismiss from clicking elsewhere - so "Show old" always resets, not just on
    /// the one path we click through ourselves. This is also where the new/old
    /// categorization watermark advances, so a session stays tagged "new" for the whole
    /// time you're actually looking at it instead of the instant you opened the popover.
    func popoverDidClose(_ notification: Notification) {
        model.showOld = false
        model.markSeenForCategorization()
    }

    @objc private func toggleLoginItem() {
        LoginItemManager.setEnabled(!LoginItemManager.isEnabled)
    }

    private static let autoCheckForUpdatesKey = "SpyProtect.autoCheckForUpdates"

    /// Defaults to on: a security tool is more useful staying current without you having
    /// to remember to check, and this only ever shows a notification (never an
    /// interrupting alert) when it finds something.
    private static var autoCheckForUpdatesEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCheckForUpdatesKey) as? Bool ?? true
    }

    private func scheduleAutoUpdateCheckIfNeeded() {
        updateCheckTimer?.invalidate()
        updateCheckTimer = nil
        guard Self.autoCheckForUpdatesEnabled else { return }

        checkForUpdatesSilently()
        // Once a day is plenty for a background check; this mirrors the retention
        // timer's cadence in Monitor for the same reason (long-running login item).
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            self?.checkForUpdatesSilently()
        }
    }

    private func checkForUpdatesSilently() {
        UpdateChecker.checkForUpdate { result in
            guard case .success(let update) = result, update.isUpdateAvailable else { return }
            NotificationManager.shared.notifyUpdateAvailable(version: update.latestVersion)
        }
    }

    @objc private func toggleAutoUpdateCheck() {
        let newValue = !Self.autoCheckForUpdatesEnabled
        UserDefaults.standard.set(newValue, forKey: Self.autoCheckForUpdatesKey)
        scheduleAutoUpdateCheckIfNeeded()
    }

    @objc private func checkForUpdatesManually() {
        UpdateChecker.checkForUpdate { [weak self] result in
            self?.presentManualUpdateCheckResult(result)
        }
    }

    private func presentManualUpdateCheckResult(_ result: Result<UpdateCheckResult, Error>) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()

        switch result {
        case .success(let update) where update.isUpdateAvailable:
            alert.messageText = "Update Available"
            alert.informativeText = "Version \(update.latestVersion) is available (you have \(update.currentVersion))."
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn, let url = update.releaseURL {
                NSWorkspace.shared.open(url)
            }
        case .success(let update):
            alert.messageText = "You're Up to Date"
            alert.informativeText = "SpyProtect \(update.currentVersion) is the latest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "Couldn't Check for Updates"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func exportLogAsPDF() {
        PDFExporter.exportAllSessions()
    }

    @objc private func clearAllLogs() {
        EventStore.shared.clearAll()
        CameraCapture.shared.clearAllPhotos()
        model.reload()
        updateIcon(hasUnseen: model.hasUnseen)
    }

    @objc private func openSecurityCheck() {
        if let window = securityCheckWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let checkModel = SecurityCheckModel()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "SpyProtect Security Check"
        window.contentView = NSHostingView(rootView: SecurityCheckView(model: checkModel))
        window.center()
        window.isReleasedWhenClosed = false
        securityCheckWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openAbout() {
        if let window = aboutWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "About SpyProtect"
        window.contentView = NSHostingView(rootView: AboutView())
        window.center()
        window.isReleasedWhenClosed = false
        aboutWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
