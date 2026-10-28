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

    /// The audit types `performAccessibilityAudit(for: .all)` covers, run one at a time: a single `.all` audit
    /// of a whole screen can exceed XCTest's internal audit time limit on slower CI simulators
    /// ("Audit failed to complete in time"), while each type alone finishes well within it.
    private static let auditTypes: [XCUIAccessibilityAuditType] = {
        let known: [XCUIAccessibilityAuditType] = [.contrast, .elementDetection, .hitRegion,
                                                   .sufficientElementDescription, .dynamicType, .textClipped, .trait]
        let rest = XCUIAccessibilityAuditType.all.subtracting(known.reduce(into: []) { $0.formUnion($1) })
        return rest.isEmpty ? known : known + [rest]
    }()

    @MainActor
    private func audit(_ app: XCUIApplication) throws {
        for type in Self.auditTypes {
            do {
                try auditOnce(app, type)
            } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 {
                // Timed out (simulator busy); retry this one type once, then let a second timeout fail the test.
                print("Accessibility audit timed out for type \(type.rawValue); retrying once")
                try auditOnce(app, type)
            }
        }
    }

    @MainActor
    private func auditOnce(_ app: XCUIApplication, _ type: XCUIAccessibilityAuditType) throws {
        try app.performAccessibilityAudit(for: type) { issue in
            let accepted = Self.isAccepted(issue)
            let element = issue.element
            print("Accessibility audit issue (\(accepted ? "accepted" : "FAILS")): type=\(issue.auditType.rawValue) "
                  + "\"\(issue.compactDescription)\" element=\(element?.elementType.rawValue ?? 0) "
                  + "id=\(element?.identifier ?? "<none>") label=\(element?.label ?? "<none>")")
            if accepted {
                print("Accepted accessibility audit issue: \(issue.compactDescription) on \(element?.identifier ?? "<no element>")")
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
        // Secondary text uses the system's semantic secondary label colour (HIG), which the audit reports as
        // "Contrast nearly passed". A real contrast failure ("Contrast failed") is still reported.
        if issue.auditType == .contrast, issue.compactDescription == "Contrast nearly passed" {
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
