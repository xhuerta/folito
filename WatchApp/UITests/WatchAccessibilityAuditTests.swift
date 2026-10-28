import XCTest

/// Runs Xcode's automated accessibility audit (`XCUIApplication.performAccessibilityAudit`, watchOS 10+) on
/// every main watch screen: empty library, library with one book, reader, Reading Options, Settings and
/// Typography. The app is launched with `-UITesting` / `-UITestingSeedSampleBook` (Debug builds only; see
/// WatchApp/Support/UITestingSupport.swift).
///
/// Consciously accepted findings are listed in `isAccepted(_:)` and in docs/ACCESSIBILITY.md
/// ("Apple Watch > Accepted audit findings").
final class WatchAccessibilityAuditTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: .all) { issue in
            let accepted = Self.isAccepted(issue)
            if accepted {
                print("Accepted accessibility audit issue: \(issue.compactDescription) on \(issue.element?.identifier ?? "<no element>")")
            }
            return accepted // true = ignore this issue; false = report it as a test failure
        }
    }

    /// Findings we accept on purpose (each one is explained in docs/ACCESSIBILITY.md).
    @MainActor
    private static func isAccepted(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        switch issue.element?.identifier {
        case "typographyPreview":
            // Content, not chrome: drawn at the reader's own point size and theme colours (what the reader shows).
            return issue.auditType == .dynamicType || issue.auditType == .contrast || issue.auditType == .textClipped
        case "readerBlock":
            // Book text uses the reader's text size (Dynamic Type only with "Match System Text Size", off by
            // default), and blocks at the top/bottom edge of the scroll view are partly off screen by design.
            return issue.auditType == .dynamicType || issue.auditType == .textClipped
        default:
            return false
        }
    }

    // MARK: Library

    @MainActor
    func testLibraryEmptyStateAudit() throws {
        let app = WatchUI.launch()
        try audit(app)
    }

    @MainActor
    func testLibraryWithBookAudit() throws {
        let app = WatchUI.launch(seedSampleBook: true)
        try audit(app)
    }

    // MARK: Reader

    @MainActor
    func testReaderAudit() throws {
        let app = WatchUI.launch(seedSampleBook: true)
        WatchUI.openReader(app)
        try audit(app)
    }

    @MainActor
    func testReadingOptionsAudit() throws {
        let app = WatchUI.launch(seedSampleBook: true)
        WatchUI.openReader(app)
        WatchUI.openReaderMenu(app)
        try audit(app)
    }

    // MARK: Settings

    @MainActor
    func testSettingsAudit() throws {
        let app = WatchUI.launch()
        WatchUI.openSettings(app)
        try audit(app)
    }

    @MainActor
    func testTypographyAudit() throws {
        let app = WatchUI.launch()
        WatchUI.openSettings(app)
        let typography = app.buttons["Typography"]
        XCTAssertTrue(WatchUI.scrollToHittable(typography, in: app), "Typography link not reachable")
        typography.tap()
        XCTAssertTrue(WatchUI.element("typographyPreview", in: app).waitForExistence(timeout: 5))
        try audit(app)
    }
}
