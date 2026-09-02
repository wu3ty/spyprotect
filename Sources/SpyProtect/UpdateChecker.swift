import Foundation

struct UpdateCheckResult {
    let isUpdateAvailable: Bool
    let latestVersion: String
    let currentVersion: String
    let releaseURL: URL?
}

/// Checks GitHub's "latest release" API for a newer version than what's currently
/// running. Uses the unauthenticated public API - works once the repo is public; while
/// it's private this fails with a clear 404-specific message rather than a cryptic parse
/// error, and nothing else needs to change once visibility flips.
enum UpdateChecker {
    private static let releasesURL = URL(string: "https://api.github.com/repos/wu3ty/spyprotect/releases/latest")!

    static func checkForUpdate(completion: @escaping (Result<UpdateCheckResult, Error>) -> Void) {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                let error = NSError(domain: "UpdateChecker", code: 404, userInfo: [
                    NSLocalizedDescriptionKey: "No release found - the repository may still be private."
                ])
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tagName = json["tag_name"] as? String
            else {
                let error = NSError(domain: "UpdateChecker", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Couldn't read release information."
                ])
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:))
            let result = UpdateCheckResult(
                isUpdateAvailable: isVersion(latestVersion, newerThan: currentVersion),
                latestVersion: latestVersion,
                currentVersion: currentVersion,
                releaseURL: htmlURL
            )
            DispatchQueue.main.async { completion(.success(result)) }
        }.resume()
    }

    /// Plain numeric dotted-version comparison ("1.2.0" > "1.10.0" is handled correctly,
    /// unlike a naive string comparison) - no external dependency needed for this.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
