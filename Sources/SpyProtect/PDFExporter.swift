import AppKit

/// Exports every stored session (all of it, not just what's currently visible in the
/// popover) as a single paginated PDF report - text only, no embedded photos, to keep
/// this simple; a snapshot's file path is noted inline for events that have one.
enum PDFExporter {
    static func exportAllSessions() {
        let sessions = EventStore.shared.all()
        let report = buildReport(sessions: sessions)

        let panel = NSSavePanel()
        panel.title = "Export SpyProtect Log"
        panel.nameFieldStringValue = "SpyProtect-Log-\(dateStamp()).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            writePDF(report, to: url)
        }
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Not private, so tests can exercise report-building and PDF writing directly
    /// without going through the (untestable, interactive) NSSavePanel in
    /// exportAllSessions.
    static func buildReport(sessions: [AwaySession]) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let titleFont = NSFont.boldSystemFont(ofSize: 20)
        let headerFont = NSFont.boldSystemFont(ofSize: 13)
        let bodyFont = NSFont.systemFont(ofSize: 11)
        let secondary = NSColor.darkGray

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .medium

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"

        func append(_ string: String, font: NSFont, color: NSColor = .black) {
            result.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }

        append("SpyProtect Activity Log\n", font: titleFont)
        append("Generated \(dateFormatter.string(from: Date()))\n\n", font: bodyFont, color: secondary)

        if sessions.isEmpty {
            append("No away sessions recorded.\n", font: bodyFont)
        }

        for session in sessions {
            let reviewedLabel = session.reviewed ? "reviewed" : "not reviewed"
            append(
                "Locked \(dateFormatter.string(from: session.lockedAt)) - away for \(Int(session.duration))s - \(reviewedLabel)\n",
                font: headerFont)

            if session.events.isEmpty {
                append("  No activity detected while locked.\n", font: bodyFont, color: secondary)
            } else {
                for event in session.events.reversed() {
                    var line = "  \(timeFormatter.string(from: event.timestamp))  [\(label(for: event.kind))]  \(event.detail)"
                    if let imagePath = event.imagePath {
                        line += "  (snapshot: \(imagePath))"
                    }
                    append(line + "\n", font: bodyFont)
                }
            }
            append("\n", font: bodyFont)
        }

        return result
    }

    private static func label(for kind: AwayEvent.Kind) -> String {
        switch kind {
        case .authFailure: return "AUTH FAILURE"
        case .usbInserted: return "USB CONNECTED"
        case .usbHIDConnected: return "HID DEVICE"
        case .usbRemoved: return "USB DISCONNECTED"
        case .appLaunched: return "APP LAUNCHED"
        }
    }

    /// NSPrintOperation with jobDisposition = .save handles pagination for us across
    /// however many sessions there are, writing straight to `url` with no print dialog.
    static func writePDF(_ report: NSAttributedString, to url: URL) {
        let printInfo = NSPrintInfo()
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: printInfo.paperSize.width, height: printInfo.paperSize.height))
        textView.textStorage?.setAttributedString(report)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
    }
}
