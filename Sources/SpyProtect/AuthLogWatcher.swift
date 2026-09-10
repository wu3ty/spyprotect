import Foundation

/// Tails the unified system log for a failed unlock/login attempt, password or Touch ID.
///
/// Filters tightly on the specific "credential check failed" phrasing rather than any
/// line mentioning "fail" (which also matches routine service teardown noise).
///
/// This is a heuristic best-effort signal: Apple doesn't expose a stable public API for
/// "auth failed" events, so we grep the log stream for known phrasing. False negatives
/// are possible if Apple changes wording; treat this as a bonus signal, not the primary one.
///
/// Source classification (password vs. Touch ID) works by correlation, not by inspecting
/// the failure line itself: the actual failure - e.g. opendirectoryd's "Authentication
/// failed: ODErrorCredentialsInvalid" - is logged identically regardless of which input
/// method produced the bad credential, so there is no keyword in that line to key off of.
/// What loginwindow *does* log distinctly is "APEventTouchIDMatch" when the Touch ID sensor
/// registers a match attempt on the lock screen - confirmed against a real captured failed
/// Touch ID unlock, where that line lands ~0.5s before the resulting "Authentication failed"
/// line. So: a failure line within a few seconds of a Touch ID match line is attributed to
/// Touch ID; otherwise it's attributed to the password field.
///
/// Deliberately fires once per matched failure line, with no debouncing/grouping - a single
/// real attempt can still surface more than one line (loginwindow and opendirectoryd each
/// log their own), but each is reported as its own raw event rather than merged into a count.
final class AuthLogWatcher {
    private let onFailure: (_ detail: String) -> Void
    private var process: Process?
    private var lastTouchIDMatchAt: Date?

    /// How long a Touch ID match line stays "recent" enough to attribute a following
    /// failure line to it - generous relative to the ~0.5s gap observed in practice.
    private static let touchIDCorrelationWindow: TimeInterval = 3

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
             OR eventMessage CONTAINS[c] "AUTH FAILED" \
             OR eventMessage CONTAINS[c] "APEventTouchIDMatch")
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        // --debug is required: APEventTouchIDMatch is logged by loginwindow at Debug
        // level, below the default Info threshold `log stream` would otherwise apply.
        // The predicate above still bounds the volume this actually streams.
        process.arguments = ["stream", "--style", "compact", "--debug", "--predicate", predicate]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where !line.hasPrefix("Filtering") && !line.hasPrefix("Timestamp") {
                guard let self else { return }
                if Self.isTouchIDMatchLine(line) {
                    self.lastTouchIDMatchAt = Date()
                    continue
                }
                let recentTouchID = Self.isRecentTouchIDMatch(
                    lastMatch: self.lastTouchIDMatchAt,
                    now: Date(),
                    window: Self.touchIDCorrelationWindow
                )
                let detail = Self.classify(recentTouchIDMatch: recentTouchID)
                DispatchQueue.main.async { self.onFailure(detail) }
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            NSLog("SpyProtect: failed to start log stream: \(error)")
        }
    }

    static func isTouchIDMatchLine(_ line: Substring) -> Bool {
        line.contains("APEventTouchIDMatch")
    }

    static func isRecentTouchIDMatch(lastMatch: Date?, now: Date, window: TimeInterval) -> Bool {
        guard let lastMatch else { return false }
        return now.timeIntervalSince(lastMatch) <= window
    }

    static func classify(recentTouchIDMatch: Bool) -> String {
        "Failed unlock attempt (\(recentTouchIDMatch ? "Touch ID" : "password"))"
    }

    deinit {
        process?.terminate()
    }
}
