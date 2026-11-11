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

    /// Library (seeded) -> reader of the first book.
    ///
    /// The row exists as soon as the Library is in the accessibility tree, which on a freshly launched app can be
    /// before the list takes taps (launch transition, covers and progress loading into the rows): such a tap is
    /// dropped and the Library stays on screen. So the row is tapped again (up to three times) while it is still
    /// showing and hittable, and once the reader is on screen ("Opening…" while the book loads) the wait goes on
    /// without tapping, up to `timeout` seconds in all. On a timeout the failure says which screen was showing
    /// and attaches a screenshot.
    static func openReader(_ app: XCUIApplication, timeout: TimeInterval = 60,
                           file: StaticString = #filePath, line: UInt = #line) {
        let row = libraryRow(in: app)
        let text = element("readerBlock", in: app)
        let deadline = Date().addingTimeInterval(timeout)
        var taps = 0
        while Date() < deadline {
            if text.exists { return }
            if taps < 3, row.exists, row.isHittable {
                row.tap()
                taps += 1
                if text.waitForExistence(timeout: 8) { return }
            } else {
                _ = text.waitForExistence(timeout: 2)
            }
        }
        if text.exists { return }
        let opening = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Opening")).element(boundBy: 0)
        let state = row.exists && row.isHittable ? "the Library is still showing"
            : opening.exists ? "the reader still shows \u{201C}Opening\u{2026}\u{201D}"
            : "neither the Library nor the book text is showing"
        fail("Reader did not show the book text within \(Int(timeout)) s after \(taps) tap(s): \(state)",
             in: app, file: file, line: line)
    }

    /// Fails the test with `message`, a screenshot of the screen (attachment "failure screen") and the
    /// accessibility tree.
    static func fail(_ message: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "failure screen"
        shot.lifetime = .keepAlways
        XCTContext.runActivity(named: message) { $0.add(shot) }
        XCTFail("\(message). Tree:\n\(app.debugDescription)", file: file, line: line)
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
