import XCTest

/// OPDS catalogs (docs/OPDS.md) with fixed feeds built in code (`-UITestingMockCatalogs`, Debug builds only; no
/// network): Library › + › Catalogs, a section of Project Gutenberg, a page of Standard Ebooks with Load More, a
/// book, the Add Catalog form and its error, and the sign-in of a self-hosted catalog (a 401 page, Sign In with a
/// wrong and the right password, Edit Catalog, Remove Sign-In). Each screen is attached at the default and the
/// largest accessibility text size; macos.yml exports them as the `catalogs-screenshots` artifact.
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
        screenshot(app, "\(size)-3-page")
        let noEPUB = app.staticTexts["Not available as EPUB"]
        for _ in 0..<6 where !(noEPUB.exists && noEPUB.isHittable) { app.swipeUp() }
        XCTAssertTrue(noEPUB.exists, "the PDF-only book says so")
        if largestText { screenshot(app, "\(size)-3b-page-end") }
        for _ in 0..<6 where !(mars.exists && mars.isHittable) { app.swipeDown() }

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

    /// Types into a field after clearing it (a secure field cannot be read back, so it is cleared by deleting).
    @MainActor
    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !(field.exists && field.isHittable) { app.swipeUp() }
        XCTAssertTrue(field.exists, "\(field) missing")
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 20))
        } else {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30))
        }
        field.typeText(text)
    }

    @MainActor
    private func tapReachable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) not reachable")
        element.tap()
    }

    @MainActor
    private func signInFlow(largestText: Bool) {
        let size = largestText ? "ax5" : "default"
        let app = launch(largestText: largestText)
        openCatalogs(app)

        // "Home Library" has a saved sign-in: its row says so.
        let home = row(app, "catalogRow", startingWith: "Home Library")
        for _ in 0..<6 where !(home.exists && home.isHittable) { app.swipeUp() }
        XCTAssertTrue(home.label.contains("Signed in as reader"), "the row shows the saved user name: \(home.label)")

        // "Family Server" answers 401: the page offers Sign In.
        let family = row(app, "catalogRow", startingWith: "Family Server")
        tapReachable(family, in: app)
        let signIn = app.buttons["catalogSignIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10), "a 401 page offers Sign In")
        screenshot(app, "\(size)-7-sign-in-needed")
        tapReachable(signIn, in: app)
        XCTAssertTrue(app.navigationBars["Sign In"].waitForExistence(timeout: 5), "Sign In did not open")
        screenshot(app, "\(size)-8-sign-in")

        // A wrong password is refused and nothing is saved.
        type("reader", into: app.textFields["catalogUsername"], in: app)
        type("wrong", into: app.secureTextFields["catalogPassword"], in: app)
        tapReachable(app.buttons["catalogEditSave"], in: app)
        let refused = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'The catalog didn’t accept'")).firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: 10), "a wrong password is explained")
        screenshot(app, "\(size)-9-sign-in-refused")

        // The right one is saved, and the page loads with it.
        type("fixture-password", into: app.secureTextFields["catalogPassword"], in: app)
        tapReachable(app.buttons["catalogEditSave"], in: app)
        XCTAssertTrue(row(app, "catalogSectionRow", startingWith: "Shared Books").waitForExistence(timeout: 10),
                      "the page loads after signing in")
        screenshot(app, "\(size)-10-signed-in")

        // Edit Catalog from the page's toolbar: the saved user name, never the password; Remove Sign-In.
        let edit = app.buttons["catalogEdit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "an added catalog's page has Edit")
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Catalog"].waitForExistence(timeout: 5), "Edit Catalog did not open")
        XCTAssertEqual(app.textFields["catalogUsername"].value as? String, "reader")
        screenshot(app, "\(size)-11-edit")
        tapReachable(app.buttons["catalogRemoveSignIn"], in: app)
        XCTAssertFalse(app.buttons["catalogRemoveSignIn"].waitForExistence(timeout: 2), "the sign-in is gone")
        app.buttons["catalogEditCancel"].tap()
        goBack(app, to: "Catalogs")
        XCTAssertTrue(row(app, "catalogRow", startingWith: "Family Server").waitForExistence(timeout: 5))
        XCTAssertFalse(row(app, "catalogRow", startingWith: "Family Server").label.contains("Signed in"),
                       "removed from the list too")
    }

    @MainActor
    func testCatalogSignInAtDefaultSize() throws {
        signInFlow(largestText: false)
    }

    @MainActor
    func testCatalogSignInAtLargestTextSize() throws {
        signInFlow(largestText: true)
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
