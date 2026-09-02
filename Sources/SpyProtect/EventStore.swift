import Foundation

struct AwayEvent: Codable, Identifiable {
    enum Kind: String, Codable {
        case authFailure
        case usbInserted
        case usbHIDConnected
        case usbRemoved
        case appLaunched
    }

    var id = UUID()
    let kind: Kind
    let timestamp: Date
    let detail: String
    /// Absolute path to a snapshot taken at the moment of this event, if one was
    /// captured (currently only for failed unlock attempts). Missing on older stored
    /// events, which decode this as nil.
    var imagePath: String?
}

struct AwaySession: Codable, Identifiable {
    var id = UUID()
    let lockedAt: Date
    let unlockedAt: Date
    var events: [AwayEvent]
    var reviewed: Bool = false

    var duration: TimeInterval { unlockedAt.timeIntervalSince(lockedAt) }
}

/// Persists away-sessions as JSON lines so history survives app restarts.
final class EventStore {
    static let shared = EventStore()

    private let fileURL: URL

    private convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpyProtect", isDirectory: true)
        self.init(directory: dir)
    }

    /// Exposed (not just `private`) so tests can point at an isolated temp directory
    /// instead of the real Application Support path.
    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("sessions.jsonl")
    }

    func append(_ session: AwaySession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        guard let line = String(data: data, encoding: .utf8) else { return }
        let handle: FileHandle
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return }
        handle = h
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write((line + "\n").data(using: .utf8)!)
    }

    func recent(limit: Int = 50) -> [AwaySession] {
        Array(readAll().suffix(limit).reversed())
    }

    private func readAll() -> [AwaySession] {
        guard let data = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AwaySession.self, from: d)
        }
    }

    /// Rewrites the log with `reviewed` toggled for the given session. O(n) in session
    /// count, which is fine at the scale (dozens to low hundreds) this app expects.
    func setReviewed(id: UUID, reviewed: Bool) {
        var all = readAll()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].reviewed = reviewed

        let encoder = JSONEncoder()
        let lines = all.compactMap { session -> String? in
            guard let data = try? encoder.encode(session) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
