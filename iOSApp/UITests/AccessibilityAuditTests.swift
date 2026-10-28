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
            var attempt = 1
            while true {
                do {
                    try auditOnce(app, type)
                    break
                } catch let error as NSError
                            where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 && attempt < 3 {
                    // "Audit failed to complete in time" (busy CI simulator): not a finding. Let the app settle and
                    // run this one type again; a third timeout fails the test.
                    print("Accessibility audit timed out for type \(type.rawValue) (attempt \(attempt)); retrying")
                    attempt += 1
                    Thread.sleep(forTimeInterval: 3)
                }
            }
        }
    }

    @MainActor
    private func auditOnce(_ app: XCUIApplication, _ type: XCUIAccessibilityAuditType) throws {
        // The handler only records findings; element queries and screenshots happen after the audit returns.
        var findings: [(issue: XCUIAccessibilityAuditIssue, accepted: Bool)] = []
        defer {
            for finding in findings { Self.log(finding.issue, accepted: finding.accepted, in: app) }
        }
        try app.performAccessibilityAudit(for: type) { issue in
            let accepted = Self.isAccepted(issue)
            findings.append((issue, accepted))
            return accepted // true = ignore this issue; false = report it as a test failure
        }
    }

    /// Prints every finding with its element, frame (and the tab bar's, which content can scroll under) and,
    /// for contrast findings, the contrast measured from a screenshot of the element, so the CI log shows
    /// exactly what was found and why. Failing findings also attach a screenshot of the screen.
    @MainActor
    private static func log(_ issue: XCUIAccessibilityAuditIssue, accepted: Bool, in app: XCUIApplication) {
        let element = issue.element
        var line = "Accessibility audit issue (\(accepted ? "accepted" : "FAILS")): type=\(issue.auditType.rawValue) "
            + "\"\(issue.compactDescription)\" element=\(element?.elementType.rawValue ?? 0) "
            + "id=\(element?.identifier ?? "<none>") label=\(element?.label ?? "<none>")"
        if let element, element.exists {
            let tabBar = app.tabBars.firstMatch
            line += " frame=\(element.frame) tabBar=\(tabBar.exists ? "\(tabBar.frame)" : "-")"
            if issue.auditType == .contrast, let measured = ContrastProbe.measure(element) {
                line += " measured=\(measured)"
            }
        }
        if !accepted {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(issue.compactDescription): \(element?.label ?? "")"
            attachment.lifetime = .keepAlways
            XCTContext.runActivity(named: "Audit finding") { $0.add(attachment) }
        }
        line += " detail=\"\(issue.detailedDescription)\""
        print(line)
    }

    /// Identifier of text drawn in a colour chosen by a system component (section header/footer, `LabeledContent`
    /// value, `ContentUnavailableView` description). Keep in sync with `SystemSecondaryText.identifier`.
    private static let systemSecondaryTextID = "systemSecondaryText"

    /// Findings we accept on purpose (each one is explained in docs/ACCESSIBILITY.md, "Accepted audit findings").
    @MainActor
    private static func isAccepted(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        let id = issue.element?.identifier
        // The reading preview is content, not chrome: it is drawn at the reader's own point size and theme
        // colours (exactly what the watch shows), so it neither follows Dynamic Type nor the system contrast.
        if id == "typographyPreview",
           issue.auditType == .dynamicType || issue.auditType == .contrast || issue.auditType == .textClipped {
            return true
        }
        // Text whose colour the system chooses (secondaryLabel in section headers/footers, LabeledContent values,
        // ContentUnavailableView descriptions) is reported as "nearly passed". Only that finding, and only on
        // those elements; text the app colours itself uses `.secondaryText` (>= 4.5:1) and must pass.
        if id == systemSecondaryTextID, issue.auditType == .contrast,
           issue.compactDescription == "Contrast nearly passed" {
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
