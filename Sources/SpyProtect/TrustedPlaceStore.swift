import Foundation

struct TrustedPlace: Codable, Identifiable, Equatable {
    var id: String { ssid }
    let ssid: String
    let addedAt: Date
}

/// Wi-Fi networks (by SSID) the user has marked as a trusted place - e.g. home. While the
/// Mac is connected to one of them, Monitor ignores everything: no camera snapshot, no
/// notification, nothing logged.
///
/// Caveat worth knowing: an SSID is just a name, so anyone can broadcast a network with the
/// same one. That's an accepted trade-off for a convenience feature, not a hard guarantee.
final class TrustedPlaceStore {
    static let shared = TrustedPlaceStore()

    private let fileURL: URL
    private let lock = NSLock()

    private convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpyProtect", isDirectory: true)
        self.init(directory: dir)
    }

    /// Exposed so tests can point at an isolated temp directory.
    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("trusted-places.json")
    }

    func isTrusted(ssid: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return load().contains { $0.ssid == ssid }
    }

    func trust(ssid: String) {
        lock.lock(); defer { lock.unlock() }
        var places = load()
        guard !places.contains(where: { $0.ssid == ssid }) else { return }
        places.append(TrustedPlace(ssid: ssid, addedAt: Date()))
        save(places)
    }

    func untrust(ssid: String) {
        lock.lock(); defer { lock.unlock() }
        save(load().filter { $0.ssid != ssid })
    }

    /// Every trusted place, oldest first.
    func all() -> [TrustedPlace] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    private func load() -> [TrustedPlace] {
        guard let data = try? Data(contentsOf: fileURL),
              let places = try? JSONDecoder().decode([TrustedPlace].self, from: data) else { return [] }
        return places.sorted { $0.addedAt < $1.addedAt }
    }

    private func save(_ places: [TrustedPlace]) {
        guard let data = try? JSONEncoder().encode(places) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
