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

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.reload()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "eye.trianglebadge.exclamationmark", accessibilityDescription: "SpyProtect")
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
        let symbol = hasUnseen ? "eye.trianglebadge.exclamationmark.fill" : "eye"
        let description = hasUnseen ? "New activity" : "SpyProtect"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
    }

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

        let unseenCount = model.sessions.count { model.isNew($0) }
        if unseenCount > 0 {
            let summary = NSMenuItem(title: "⚠️ \(unseenCount) new away session(s) with activity", action: nil, keyEquivalent: "")
            summary.isEnabled = false
            menu.addItem(summary)
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Clear All Logs", action: #selector(clearAllLogs), keyEquivalent: ""))
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
        model.reload()
        updateIcon(hasUnseen: model.hasUnseen)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
