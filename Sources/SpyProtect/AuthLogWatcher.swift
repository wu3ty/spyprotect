import Foundation

/// Tails the unified system log for a failed unlock/login password attempt.
///
/// Filters tightly on the specific "credential check failed" phrasing rather than any
/// line mentioning "fail" (which also matches routine service teardown noise).
///
/// This is a heuristic best-effort signal: Apple doesn't expose a stable public API for
/// "auth failed" events, so we grep the log stream for known phrasing. False negatives
/// are possible if Apple changes wording; treat this as a bonus signal, not the primary one.
///
/// Deliberately fires once per matched line, with no debouncing/grouping - a single real
/// attempt can still surface more than one line (loginwindow and opendirectoryd each log
/// their own), but each is reported as its own raw event rather than merged into a count.
final class AuthLogWatcher {
    private let onFailure: (_ detail: String) -> Void
    private var process: Process?

    init(onFailure: @escaping (_ detail: String) -> Void) {
        self.onFailure = onFailure
    }

    func start() {
        let predicate = """
        (process == "loginwindow" OR process == "SecurityAgent" OR process == "opendirectoryd") \
        AND (eventMessage CONTAINS[c] "authentication failed" \
             OR eventMessage CONTAINS[c] "incorrect password" \
             OR eventMessage CONTAINS[c] "invalid password" \
             OR eventMessage CONTAINS[c] "Login Failed" \
             OR eventMessage CONTAINS[c] "checkpw" \
             OR eventMessage CONTAINS[c] "AUTH FAILED")
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "compact", "--predicate", predicate]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where !line.hasPrefix("Filtering") && !line.hasPrefix("Timestamp") {
                DispatchQueue.main.async { self?.onFailure("Failed unlock attempt") }
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("SpyProtect: failed to start log stream: \(error)")
        }
    }

    deinit {
        process?.terminate()
    }
}
