import AppKit
import Foundation

/// Downloads a release's `SpyProtect.zip`, unzips it, swaps it in for the currently
/// running app bundle, and relaunches - the actual "install" half of update checking,
/// which previously only ever offered "View Release" (open the GitHub page and have the
/// user download/replace it by hand).
enum AppUpdater {
    enum UpdateError: LocalizedError {
        case extractionFailed
        case appNotFoundInArchive
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .extractionFailed:
                return "Couldn't unzip the downloaded update."
            case .appNotFoundInArchive:
                return "The downloaded update doesn't contain SpyProtect.app."
            case .installFailed(let reason):
                return "Couldn't install the update: \(reason)"
            }
        }
    }

    /// Calls back on the main queue. On success the app is already relaunching and about
    /// to quit, so there's nothing further for the caller to do.
    static func downloadAndInstall(assetURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        URLSession.shared.downloadTask(with: assetURL) { tempFileURL, _, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let tempFileURL else {
                DispatchQueue.main.async {
                    completion(.failure(UpdateError.installFailed("No file was downloaded.")))
                }
                return
            }

            do {
                try install(downloadedZip: tempFileURL)
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    private static func install(downloadedZip: URL) throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("SpyProtectUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // ditto both creates the release zip (see release.yml's "Zip app bundle" step,
        // which uses --keepParent so SpyProtect.app is the top-level entry) and extracts
        // it - no separate unzip dependency needed.
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", downloadedZip.path, workDir.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw UpdateError.extractionFailed }

        let newAppURL = workDir.appendingPathComponent("SpyProtect.app")
        guard fm.fileExists(atPath: newAppURL.path) else { throw UpdateError.appNotFoundInArchive }

        // Defensive: this was fetched via URLSession, not Finder/a browser, so it
        // shouldn't carry Gatekeeper's quarantine flag - but strip it if present anyway,
        // so relaunching never hits an "unidentified developer" prompt.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", newAppURL.path]
        try? xattr.run()
        xattr.waitUntilExit()

        let installedAppURL = try replace(Bundle.main.bundleURL, with: newAppURL)
        relaunch(at: installedAppURL)
    }

    /// Removing the currently-running app bundle's path doesn't affect this process - by
    /// the time this runs, the executable is already loaded from the open (soon-to-be
    /// unlinked) inode, so replacing the path out from under it is safe on macOS.
    private static func replace(_ currentAppURL: URL, with newAppURL: URL) throws -> URL {
        let fm = FileManager.default
        do {
            try fm.removeItem(at: currentAppURL)
            try fm.moveItem(at: newAppURL, to: currentAppURL)
            return currentAppURL
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }

    /// Spawns the new app after a short delay - long enough for this process to have
    /// fully quit - so the new instance's isOnlyInstance() check doesn't see this one
    /// still running and immediately exit itself.
    private static func relaunch(at appURL: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(appURL.path)\""]
        try? task.run()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}
