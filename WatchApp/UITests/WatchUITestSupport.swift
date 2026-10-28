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
        XCTAssertTrue(element("chapterButton", in: app).waitForExistence(timeout: 5),
                      "Reading Options did not open (no chapter button)", file: file, line: line)
    }

    /// Scrolls the current screen (crown-like swipes) until `element` is hittable. Returns whether it is.
    @discardableResult
    static func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 6) -> Bool {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
        return element.exists && element.isHittable
    }
}
