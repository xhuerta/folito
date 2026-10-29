import XCTest

/// Launch and navigation helpers shared by the watch UI tests. The app is launched with `-UITesting` (empty,
/// throw-away library, no WatchConnectivity) or `-UITestingSeedSampleBook` (one built-in sample book); both are
/// handled in Debug builds only, see WatchApp/Support/UITestingSupport.swift.
@MainActor
enum WatchUI {
    static let sampleTitle = "Alice’s Adventures in Wonderland"
    static let sampleChapter = "Down the Rabbit-Hole"

    /// Launch arguments that make the app start at the largest accessibility text size
    /// (`UIContentSizeCategory.accessibilityExtraExtraExtraLarge`).
    static let accessibilityXXXLArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    static func launch(seedSampleBook: Bool = false, extraArguments: [String] = [],
                       file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += seedSampleBook ? ["-UITestingSeedSampleBook"] : ["-UITesting"]
        app.launchArguments += extraArguments
        app.launch()
        let ready = seedSampleBook ? libraryRow(in: app) : emptyLibraryMessage(in: app)
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "Library screen did not appear", file: file, line: line)
        return app
    }

    static func libraryRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "libraryRow").element(boundBy: 0)
    }

    /// The empty-state title. Matched by label because ContentUnavailableView may merge its title and
    /// description into one element.
    static func emptyLibraryMessage(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "No Books")).element(boundBy: 0)
    }

    static func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).element(boundBy: 0)
    }

    /// Library -> Settings.
    static func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = element("settingsButton", in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Settings button missing", file: file, line: line)
        button.tap()
        XCTAssertTrue(element("textSizeStepper", in: app).waitForExistence(timeout: 5),
                      "Settings did not open (no text size stepper)", file: file, line: line)
    }

    /// Library (seeded) -> reader of the sample book.
    static func openReader(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        libraryRow(in: app).tap()
        XCTAssertTrue(element("readerBlock", in: app).waitForExistence(timeout: 15),
                      "Reader did not show the book text", file: file, line: line)
    }

    /// Reader -> Reading Options sheet (text size, dictionary, chapters).
    static func openReaderMenu(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = element("readerOptionsButton", in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Reading Options button missing", file: file, line: line)
        button.tap()
        // The text size stepper is the sheet's first row; the chapter list is further down and, in a lazy
        // List on a small watch, only enters the accessibility tree once scrolled into view.
        XCTAssertTrue(element("textSizeStepper", in: app).waitForExistence(timeout: 5),
                      "Reading Options did not open (no text size stepper)", file: file, line: line)
    }

    /// Settings or Reading Options -> Typography editor.
    static func openTypography(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // By identifier, or by its label: on watchOS a NavigationLink row may not carry the identifier set on it.
        let byID = element("typographyLink", in: app)
        let byLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Typography")).element(boundBy: 0)
        var steps = 0
        while !(byID.exists && byID.isHittable) && !(byLabel.exists && byLabel.isHittable) && steps < 12 {
            nudgeUp(app)
            steps += 1
        }
        let link = byID.exists && byID.isHittable ? byID : byLabel
        XCTAssertTrue(link.exists && link.isHittable,
                      "Typography link not reachable. Tree:\n\(app.debugDescription)", file: file, line: line)
        link.tap()
        XCTAssertTrue(element("typographyPreview", in: app).waitForExistence(timeout: 5),
                      "Typography editor did not open", file: file, line: line)
    }

    /// Scrolls the current screen in small steps (about a third of the screen per drag, so a row just below the
    /// edge is not skipped, as a full swipe does on a 40 mm watch) until `element` is hittable. Returns whether
    /// it is.
    @discardableResult
    static func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, maxSteps: Int = 12) -> Bool {
        var steps = 0
        while !(element.exists && element.isHittable) && steps < maxSteps {
            nudgeUp(app)
            steps += 1
        }
        return element.exists && element.isHittable
    }

    /// Drags the content up by roughly a third of the screen.
    static func nudgeUp(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}
