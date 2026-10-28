import XCTest

/// Runs Xcode's automated accessibility audit (`performAccessibilityAudit`, iOS 17+) on every main screen.
/// The app is launched with `-UITesting` so it uses an empty, throw-away library (Debug builds only; see
/// iOSApp/Support/UITestingSupport.swift), or with `-UITestingSeedSampleBook` for a one-book library.
///
/// Consciously accepted findings are listed in `isAccepted(_:)` and in docs/ACCESSIBILITY.md.
final class AccessibilityAuditTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(seedSampleBook: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += seedSampleBook ? ["-UITestingSeedSampleBook"] : ["-UITesting"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 15), "Library screen did not appear")
        return app
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

    /// Findings we accept on purpose (each one is explained in docs/ACCESSIBILITY.md, "Accepted audit findings").
    @MainActor
    private static func isAccepted(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        // The reading preview is content, not chrome: it is drawn at the reader's own point size and theme
        // colours (exactly what the watch shows), so it neither follows Dynamic Type nor the system contrast.
        if issue.element?.identifier == "typographyPreview",
           issue.auditType == .dynamicType || issue.auditType == .contrast || issue.auditType == .textClipped {
            return true
        }
        return false
    }

    // MARK: Library

    @MainActor
    func testLibraryEmptyStateAudit() throws {
        let app = launch()
        XCTAssertFalse(app.descendants(matching: .any)["libraryRow"].exists, "Library should start empty")
        try audit(app)
    }

    @MainActor
    func testLibraryWithBookAudit() throws {
        let app = launch(seedSampleBook: true)
        let row = app.descendants(matching: .any)["libraryRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Seeded sample book not shown")
        XCTAssertTrue(row.label.contains("Alice"), "Row should be one element that includes the title: \(row.label)")
        try audit(app)
    }

    // MARK: Settings

    @MainActor
    func testSettingsAudit() throws {
        let app = launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        try audit(app)

        app.descendants(matching: .any)["syncSettingsLink"].tap()
        XCTAssertTrue(app.navigationBars["Progress Sync"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Create account"].exists, "Account creation must stay out of the app (5.1.1(v))")
        try audit(app)
    }

    @MainActor
    func testAcknowledgementsAudit() throws {
        let app = launch()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Acknowledgements"].tap()
        XCTAssertTrue(app.navigationBars["Acknowledgements"].waitForExistence(timeout: 5))
        try audit(app)
    }

    @MainActor
    func testReadingSettingsAudit() throws {
        let app = launch()
        app.tabBars.buttons["Reading"].tap()
        XCTAssertTrue(app.navigationBars["Reading"].waitForExistence(timeout: 5))
        try audit(app)
    }
}
