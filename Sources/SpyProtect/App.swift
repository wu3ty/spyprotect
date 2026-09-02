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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        Monitor.shared.start()
        updateIcon(hasUnseen: model.hasUnseen)
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

        let unseenCount = model.sessions.filter { model.isNew($0) }.count
        if unseenCount > 0 {
            let summary = NSMenuItem(title: "⚠️ \(unseenCount) new away session(s) with activity", action: nil, keyEquivalent: "")
            summary.isEnabled = false
            menu.addItem(summary)
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Run Security Check…", action: #selector(openSecurityCheck), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear All Logs", action: #selector(clearAllLogs), keyEquivalent: ""))
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
