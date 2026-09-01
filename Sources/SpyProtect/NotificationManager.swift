import Foundation
import UserNotifications

/// Fires transient (non-persistent) banner notifications the moment a security-relevant
/// event is recorded, so you don't have to wait until you unlock and open the popover to
/// find out something happened while you were away.
///
/// Uses UNUserNotificationCenter, which requires a real signed .app bundle with a bundle
/// identifier - SpyProtect is now built and launched that way (see build_app.sh) rather
/// than as a bare executable, specifically so this has its own identity in System
/// Settings > Notifications instead of borrowing Script Editor's via osascript.
final class NotificationManager {
    static let shared = NotificationManager()

    private var authorized = false

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            self.authorized = granted
            if let error {
                NSLog("SpyProtect: notification authorization error: \(error)")
            } else {
                NSLog("SpyProtect: notification authorization granted=\(granted)")
            }
        }
    }

    /// Fired once on launch so there's an easy, repeatable way to confirm notifications
    /// are actually showing up without having to lock/unlock or wait for a real event.
    func notifyStartupCheck() {
        send(body: "SpyProtect is watching for activity while your screen is locked.",
             title: "SpyProtect", subtitle: "System observed - started")
    }

    func notify(kind: AwayEvent.Kind, detail: String) {
        guard Self.isSecurityRelevant(kind) else { return }
        send(body: detail, title: "SpyProtect", subtitle: title(for: kind))
    }

    /// Fires once, right after unlock, summarizing every security-relevant event found
    /// in that away session - separate from the real-time per-event notifications, so
    /// unlocking always gives you one clear "here's what happened" signal even if you
    /// missed the individual banners while you were away.
    func notifySessionSummary(_ session: AwaySession) {
        let relevant = session.events.filter { Self.isSecurityRelevant($0.kind) }
        guard !relevant.isEmpty else { return }

        var counts: [AwayEvent.Kind: Int] = [:]
        for event in relevant { counts[event.kind, default: 0] += 1 }

        let parts = counts.sorted { $0.key.rawValue < $1.key.rawValue }.map { kind, count in
            count > 1 ? "\(count)x \(title(for: kind))" : title(for: kind)
        }
        let body = parts.joined(separator: ", ")
        let subtitle = relevant.count == 1 ? "1 security event while you were away" : "\(relevant.count) security events while you were away"
        send(body: body, title: "SpyProtect", subtitle: subtitle, sound: .default)
    }

    private func send(body: String, title: String, subtitle: String, sound: UNNotificationSound? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        if let sound { content.sound = sound }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("SpyProtect: failed to post notification: \(error)")
            }
        }
    }

    private static func isSecurityRelevant(_ kind: AwayEvent.Kind) -> Bool {
        switch kind {
        case .authFailure, .usbInserted, .usbRemoved: return true
        case .appLaunched: return false
        }
    }

    private func title(for kind: AwayEvent.Kind) -> String {
        switch kind {
        case .authFailure: return "Failed unlock attempt"
        case .usbInserted: return "USB device connected"
        case .usbRemoved: return "USB device disconnected"
        case .appLaunched: return "App launched"
        }
    }
}
