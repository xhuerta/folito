import XCTest

/// OPDS catalogs (docs/OPDS.md) with fixed feeds built in code (`-UITestingMockCatalogs`, Debug builds only; no
/// network): Library › + › Catalogs, a section of Project Gutenberg, a page of Standard Ebooks with Load More, a
/// book, the Add Catalog form and its error. Each screen is attached at the default and the largest accessibility
/// text size; macos.yml exports them as the `catalogs-screenshots` artifact.
final class CatalogsUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(largestText: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITesting", "-UITestingMockCatalogs"]
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 15), "Library screen did not appear")
        return app
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ identifier: String, startingWith title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", identifier, title)).firstMatch
    }

    @MainActor
    private func openCatalogs(_ app: XCUIApplication) {
        app.buttons["libraryAddMenu"].tap()
        XCTAssertTrue(app.buttons["Import EPUB"].waitForExistence(timeout: 5), "the add menu keeps Import EPUB")
        let item = app.buttons["libraryCatalogs"].exists ? app.buttons["libraryCatalogs"] : app.buttons["Catalogs"]
        item.tap()
        XCTAssertTrue(app.navigationBars["Catalogs"].waitForExistence(timeout: 5), "Catalogs did not open")
    }

    /// Taps the back button of the pushed screen (labelled with the previous title, or "Back").
    @MainActor
    private func goBack(_ app: XCUIApplication, to title: String) {
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", [title, "Back"])).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "No back button to \(title)")
        back.tap()
    }

    @MainActor
    private func walkThrough(largestText: Bool) {
        let size = largestText ? "ax5" : "default"
        let app = launch(largestText: largestText)
        openCatalogs(app)
        XCTAssertTrue(row(app, "catalogRow", startingWith: "Standard Ebooks").waitForExistence(timeout: 5))
        XCTAssertTrue(row(app, "catalogRow", startingWith: "Project Gutenberg").exists)
        screenshot(app, "\(size)-1-catalogs")
        let home = row(app, "catalogRow", startingWith: "Home Library")
        for _ in 0..<6 where !(home.exists && home.isHittable) { app.swipeUp() }
        XCTAssertTrue(home.exists, "the added catalog is listed")
        if largestText { screenshot(app, "\(size)-1b-catalogs-added") }
        for _ in 0..<6 where !row(app, "catalogRow", startingWith: "Project Gutenberg").isHittable { app.swipeDown() }

        // A navigation feed.
        row(app, "catalogRow", startingWith: "Project Gutenberg").tap()
        XCTAssertTrue(row(app, "catalogSectionRow", startingWith: "Popular").waitForExistence(timeout: 10))
        screenshot(app, "\(size)-2-gutenberg")
        goBack(app, to: "Catalogs")

        // A page of books.
        let standard = row(app, "catalogRow", startingWith: "Standard Ebooks")
        // At AX5 the first rows may be above the screen after the scrolling above.
        for _ in 0..<6 where !(standard.exists && standard.isHittable) { app.swipeDown() }
        XCTAssertTrue(standard.waitForExistence(timeout: 5), "Standard Ebooks not reachable")
        standard.tap()
        let mars = row(app, "catalogBookRow", startingWith: "A Fighting Man of Mars")
        XCTAssertTrue(mars.waitForExistence(timeout: 10), "Catalog page did not load")
        XCTAssertTrue(app.staticTexts["Not available as EPUB"].exists, "the PDF-only book says so")
        screenshot(app, "\(size)-3-page")

        mars.tap()
        XCTAssertTrue(app.buttons["catalogDownload"].waitForExistence(timeout: 5), "Book screen did not open")
        screenshot(app, "\(size)-4-book")
        goBack(app, to: "Standard Ebooks")
        XCTAssertTrue(mars.waitForExistence(timeout: 5))
        goBack(app, to: "Catalogs")

        // Add Catalog, and the error for an address that is not one.
        let add = app.buttons["catalogsAdd"]
        for _ in 0..<6 where !(add.exists && add.isHittable) { app.swipeUp() }
        add.tap()
        XCTAssertTrue(app.navigationBars["Add Catalog"].waitForExistence(timeout: 5), "Add Catalog did not open")
        XCTAssertEqual(app.textFields["catalogAddress"].value as? String, "https://")
        screenshot(app, "\(size)-5-add")
        let confirm = app.buttons["catalogAddConfirm"]
        for _ in 0..<6 where !(confirm.exists && confirm.isHittable) { app.swipeUp() }
        confirm.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Enter a web address'"))
                        .firstMatch.waitForExistence(timeout: 5), "an empty address is explained")
        screenshot(app, "\(size)-6-add-error")
    }

    @MainActor
    func testCatalogsAtDefaultSize() throws {
        walkThrough(largestText: false)
    }

    @MainActor
    func testCatalogsAtLargestTextSize() throws {
        walkThrough(largestText: true)
    }
}
