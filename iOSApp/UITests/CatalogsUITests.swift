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
        // Rows are reached and opened with `RowNavigation` (deterministic drags; a catalog row is up to 380 pt
        // tall at AX5, see its comment).
        let home = row(app, "catalogRow", startingWith: "Home Library")
        RowNavigation.reveal(home, in: app)
        XCTAssertTrue(home.exists, "the added catalog is listed")
        if largestText { screenshot(app, "\(size)-1b-catalogs-added") }

        // A navigation feed.
        let popular = row(app, "catalogSectionRow", startingWith: "Popular")
        RowNavigation.open(row(app, "catalogRow", startingWith: "Project Gutenberg"), in: app, expecting: popular)
        XCTAssertTrue(popular.waitForExistence(timeout: 10))
        screenshot(app, "\(size)-2-gutenberg")
        goBack(app, to: "Catalogs")

        // A page of books.
        let standard = row(app, "catalogRow", startingWith: "Standard Ebooks")
        XCTAssertTrue(standard.waitForExistence(timeout: 5), "Standard Ebooks not reachable")
        let mars = row(app, "catalogBookRow", startingWith: "A Fighting Man of Mars")
        RowNavigation.open(standard, in: app, expecting: mars)
        XCTAssertTrue(mars.waitForExistence(timeout: 10), "Catalog page did not load")
        screenshot(app, "\(size)-3-page")
        let noEPUB = app.staticTexts["Not available as EPUB"]
        RowNavigation.reveal(noEPUB, in: app)
        XCTAssertTrue(noEPUB.exists, "the PDF-only book says so")
        if largestText { screenshot(app, "\(size)-3b-page-end") }

        RowNavigation.open(mars, in: app, expecting: app.buttons["catalogDownload"])
        XCTAssertTrue(app.buttons["catalogDownload"].waitForExistence(timeout: 5), "Book screen did not open")
        screenshot(app, "\(size)-4-book")
        goBack(app, to: "Standard Ebooks")
        XCTAssertTrue(mars.waitForExistence(timeout: 5))
        goBack(app, to: "Catalogs")

        // Add Catalog, and the error for an address that is not one.
        let add = app.buttons["catalogsAdd"]
        RowNavigation.open(add, in: app, expecting: app.navigationBars["Add Catalog"], timeout: 5)
        XCTAssertTrue(app.navigationBars["Add Catalog"].waitForExistence(timeout: 5), "Add Catalog did not open")
        XCTAssertEqual(app.textFields["catalogAddress"].value as? String, "https://")
        screenshot(app, "\(size)-5-add")
        let confirm = app.buttons["catalogAddConfirm"]
        RowNavigation.reveal(confirm, in: app)
        confirm.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Enter a web address'"))
                        .firstMatch.waitForExistence(timeout: 5), "an empty address is explained")
        screenshot(app, "\(size)-6-add-error")
    }

    /// Types into a field after clearing it (a secure field cannot be read back, so it is cleared by deleting).
    @MainActor
    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        RowNavigation.reveal(field, in: app)
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
        RowNavigation.reveal(element, in: app)
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
        RowNavigation.reveal(home, in: app)
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
