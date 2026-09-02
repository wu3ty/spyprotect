import XCTest
@testable import SpyProtect

final class PDFExporterTests: XCTestCase {
    func testBuildReportIncludesAllSessionsAndEventDetails() {
        let sessions = [
            AwaySession(
                lockedAt: Date(timeIntervalSinceReferenceDate: 1000),
                unlockedAt: Date(timeIntervalSinceReferenceDate: 1060),
                events: [
                    AwayEvent(kind: .authFailure, timestamp: Date(timeIntervalSinceReferenceDate: 1010), detail: "Failed unlock attempt", imagePath: "/tmp/snap.jpg")
                ]
            ),
            AwaySession(
                lockedAt: Date(timeIntervalSinceReferenceDate: 2000),
                unlockedAt: Date(timeIntervalSinceReferenceDate: 2030),
                events: []
            ),
        ]

        let report = PDFExporter.buildReport(sessions: sessions).string

        XCTAssertTrue(report.contains("SpyProtect Activity Log"))
        XCTAssertTrue(report.contains("Failed unlock attempt"))
        XCTAssertTrue(report.contains("AUTH FAILURE"))
        XCTAssertTrue(report.contains("/tmp/snap.jpg"))
        XCTAssertTrue(report.contains("No activity detected while locked."))
    }

    func testBuildReportHandlesNoSessions() {
        let report = PDFExporter.buildReport(sessions: []).string
        XCTAssertTrue(report.contains("No away sessions recorded."))
    }

    func testWritePDFProducesAValidPDFFile() {
        let report = PDFExporter.buildReport(sessions: [
            AwaySession(lockedAt: Date(), unlockedAt: Date().addingTimeInterval(30), events: [])
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpyProtectTest-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        PDFExporter.writePDF(report, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try? Data(contentsOf: url)
        XCTAssertNotNil(data)
        XCTAssertTrue(data.map { $0.starts(with: "%PDF".data(using: .ascii)!) } ?? false)
    }
}
