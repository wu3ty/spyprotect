import SwiftUI
import AppKit

final class SessionListModel: ObservableObject {
    @Published var sessions: [AwaySession] = []
    @Published var showOld = false

    /// Drives the "OLD" tag / hide-old filtering. Deliberately only advances when the
    /// popover *closes* (see `markSeenForCategorization`), so a session stays visible and
    /// tagged "new" for the whole time you're looking at it, not just the split second
    /// before you open the popover.
    @Published private(set) var lastSeenAt: Date

    /// Drives only the menu bar badge. Advances the moment you click the icon (separate
    /// from `lastSeenAt` - conflating the two used to mean opening the popover
    /// instantly re-stamped every session you were about to look at as "old", since
    /// "now" is always later than any already-completed session's lock time).
    private var badgeClearedAt: Date

    /// Called whenever whether there's unseen activity changes, so the status bar icon
    /// can reflect new critical events immediately.
    var onUnseenChanged: ((Bool) -> Void)?

    /// Called when "Trusted Devices" is tapped - AppDelegate owns opening the actual
    /// window, same as it does for the security check and about windows.
    var onShowTrustedDevices: (() -> Void)?

    private static let lastSeenKey = "SpyProtect.lastSeenAt"
    private static let badgeClearedKey = "SpyProtect.badgeClearedAt"

    /// Injectable so tests can use an isolated suite instead of polluting/reading the
    /// real app's persisted defaults.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastSeenAt = defaults.object(forKey: Self.lastSeenKey) as? Date ?? .distantPast
        badgeClearedAt = defaults.object(forKey: Self.badgeClearedKey) as? Date ?? .distantPast
    }

    var hasUnseen: Bool {
        sessions.contains { $0.lockedAt > badgeClearedAt }
    }

    var oldCount: Int {
        sessions.filter { !isNew($0) }.count
    }

    func isNew(_ session: AwaySession) -> Bool {
        session.lockedAt > lastSeenAt
    }

    func reload() {
        sessions = EventStore.shared.recent()
    }

    func prepend(_ session: AwaySession) {
        sessions.insert(session, at: 0)
        onUnseenChanged?(hasUnseen)
    }

    func setReviewed(_ session: AwaySession, reviewed: Bool) {
        EventStore.shared.setReviewed(id: session.id, reviewed: reviewed)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].reviewed = reviewed
        }
    }

    /// Call the instant the icon is clicked, so the badge disappears right away.
    func clearBadge() {
        guard hasUnseen else { return }
        badgeClearedAt = Date()
        defaults.set(badgeClearedAt, forKey: Self.badgeClearedKey)
        onUnseenChanged?(false)
    }

    /// Call when the popover closes, so everything you had a chance to look at this time
    /// around is tagged "old" starting next time - not the moment you opened it.
    func markSeenForCategorization() {
        lastSeenAt = Date()
        defaults.set(lastSeenAt, forKey: Self.lastSeenKey)
    }
}

struct SessionListView: View {
    @ObservedObject var model: SessionListModel

    private var visibleSessions: [AwaySession] {
        model.showOld ? model.sessions : model.sessions.filter { model.isNew($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let logo = Bundle.main.image(forResource: "AppLogoSmall") {
                    Image(nsImage: logo)
                        .resizable()
                        .frame(width: 24, height: 24)
                }
                Text("SpyProtect")
                    .font(.title2).bold()
                Spacer()
                Button("Trusted Devices") {
                    model.onShowTrustedDevices?()
                }
                .font(.body)
                if model.oldCount > 0 {
                    Button(model.showOld ? "Hide old" : "Show \(model.oldCount) old") {
                        model.showOld.toggle()
                    }
                    .font(.body)
                }
            }
            .padding()
            Divider()
            if model.sessions.isEmpty {
                Text("No away sessions recorded yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else if visibleSessions.isEmpty {
                Text("No new activity. Older sessions are hidden - tap \"Show \(model.oldCount) old\" above to view them.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(visibleSessions) { session in
                    SessionRow(session: session, isNew: model.isNew(session), onToggleReviewed: {
                        model.setReviewed(session, reviewed: !session.reviewed)
                    })
                }
                .listStyle(.plain)
            }
        }
    }
}

struct SessionRow: View {
    let session: AwaySession
    let isNew: Bool
    let onToggleReviewed: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    private static let eventTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(action: onToggleReviewed) {
                    Image(systemName: session.reviewed ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(session.reviewed ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(session.reviewed ? "Mark as unreviewed" : "Mark as reviewed")

                Text(Self.timeFormatter.string(from: session.lockedAt))
                    .font(.body).bold()
                    .strikethrough(session.reviewed)
                    .foregroundStyle(session.reviewed ? .secondary : .primary)

                if !isNew {
                    Text("OLD")
                        .font(.caption).bold()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                Spacer()
                Text(durationString(session.duration))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if session.events.isEmpty {
                Text("No activity detected while locked.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.events.reversed()) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: event.kind))
                            .font(.subheadline)
                            .foregroundStyle(color(for: event.kind))
                            .frame(width: 18)
                        Text(Self.eventTimeFormatter.string(from: event.timestamp))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(event.detail)
                            .font(.subheadline)
                            .lineLimit(3)
                        if let imagePath = event.imagePath {
                            Spacer()
                            SnapshotThumbnail(path: imagePath)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .opacity(isNew ? 1.0 : 0.5)
    }

    private func durationString(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s away" : "\(seconds)s away"
    }

    private func icon(for kind: AwayEvent.Kind) -> String {
        switch kind {
        case .authFailure: return "exclamationmark.lock"
        case .usbInserted: return "externaldrive.badge.plus"
        case .usbHIDConnected: return "keyboard.badge.exclamationmark"
        case .usbRemoved: return "externaldrive.badge.minus"
        case .appLaunched: return "app.badge"
        }
    }

    private func color(for kind: AwayEvent.Kind) -> Color {
        switch kind {
        case .authFailure, .usbHIDConnected: return .red
        case .usbInserted, .usbRemoved: return .orange
        case .appLaunched: return .blue
        }
    }
}

/// Small preview of a captured snapshot; clicking opens the full-size image in the
/// system's default image viewer (Preview.app).
struct SnapshotThumbnail: View {
    let path: String

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } label: {
            if let nsImage = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .buttonStyle(.plain)
        .help("Click to view full size")
    }
}
