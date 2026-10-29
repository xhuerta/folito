import XCTest

// TEMPORARY: experiments to understand which audit findings depend on the screen position of an element.
// Prints findings only; never fails. Removed before merging.
final class AuditExperimentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 300
    }

    private static let ax5 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    private func out(_ s: String) { FileHandle.standardOutput.write(Data(("EXPERIMENT " + s + "\n").utf8)) }

    @MainActor
    private func launch(_ extra: [String] = [], seed: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += (seed ? ["-UITestingSeedSampleBook"] : ["-UITesting"]) + extra
        app.launch()
        _ = app.navigationBars["Library"].waitForExistence(timeout: 15)
        return app
    }

    @MainActor
    private func run(_ name: String, _ app: XCUIApplication, _ type: XCUIAccessibilityAuditType) {
        var issues: [XCUIAccessibilityAuditIssue] = []
        var err = ""
        do {
            try app.performAccessibilityAudit(for: type) { issues.append($0); return true }
        } catch { err = " error=\(error)" }
        out("\(name) type=\(type.rawValue): \(issues.count) findings\(err)")
        for i in issues {
            let e = i.element
            let frame = (e?.exists ?? false) ? "\(e!.frame)" : "-"
            out("\(name)   \(i.compactDescription) | \(e?.label ?? "-") | \(frame)")
        }
        // Also list every static text with its frame, to see which ones passed.
        if type == .dynamicType {
            for t in app.staticTexts.allElementsBoundByIndex.prefix(40) {
                out("\(name)   text: \(t.label.prefix(40)) | \(t.frame)")
            }
        }
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        _ = app.navigationBars["Settings"].waitForExistence(timeout: 5)
    }

    @MainActor
    func testE1SettingsDefault() {
        let app = launch(); openSettings(app)
        run("E1 settings default", app, .dynamicType)
        run("E1 settings default", app, .textClipped)
    }

    @MainActor
    func testE2SettingsAX5() {
        let app = launch(Self.ax5); openSettings(app)
        run("E2 settings AX5", app, .dynamicType)
        run("E2 settings AX5", app, .textClipped)
        run("E2 settings AX5", app, .contrast)
    }

    @MainActor
    func testE3SettingsDefaultScrolled() {
        let app = launch(); openSettings(app)
        app.collectionViews.firstMatch.swipeUp()
        run("E3 settings scrolled", app, .dynamicType)
        run("E3 settings scrolled", app, .textClipped)
    }

    @MainActor
    func testE4LibraryBookAX5() {
        let app = launch(Self.ax5, seed: true)
        run("E4 library AX5", app, .dynamicType)
        run("E4 library AX5", app, .textClipped)
    }

    @MainActor
    func testE5ReadingContrast() {
        let app = launch()
        app.tabBars.buttons["Reading"].tap()
        _ = app.navigationBars["Reading"].waitForExistence(timeout: 5)
        run("E5 reading top", app, .contrast)
        app.collectionViews.firstMatch.swipeUp()
        run("E5 reading scrolled", app, .contrast)
        run("E5 reading scrolled", app, .dynamicType)
    }
}
