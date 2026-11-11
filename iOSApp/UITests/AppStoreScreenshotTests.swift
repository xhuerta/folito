import XCTest

/// The iPhone screenshots of the App Store listing (docs/appstore/SCREENSHOTS.md): the Library, a book's
/// details and the Reading tab with its live preview. Launched with `-UITestingSeedCovers` (Debug builds only:
/// public-domain books with generated covers), built from the full texts in `AppStoreBooks` (so the Library shows
/// real book sizes), and `-UITestingSimulateWatch`, which shows the Library as with a paired, reachable Apple Watch
/// that already has the books (nothing is sent; Release builds ignore both). The whole screen is captured,
/// status bar included; macos.yml runs this suite on one simulator per required App Store display size, with the
/// status bar overridden (9:41, full battery, no carrier name), and exports the attachments as the
/// `app-store-screenshots` artifact.
final class AppStoreScreenshotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'libraryRow' AND label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor
    func testAppStoreScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestingSeedCovers", "-UITestingSimulateWatch", "-UITestingSkipOnboarding",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // The simulator app reads the texts straight from this test bundle (a folder reference in project.yml).
        let texts = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "AppStoreBooks", withExtension: nil),
                                  "AppStoreBooks missing from the UI test bundle")
        app.launchEnvironment["UITESTING_BOOK_TEXTS"] = texts.path
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 20), "Library screen did not appear")
        let mars = row(app, "The Gods of Mars")
        XCTAssertTrue(mars.waitForExistence(timeout: 20), "seeded books missing")
        // Checked at the end, so that a wrong Library still yields all three captures to look at.
        let labels = ["The Gods of Mars", "Emma", "Alice"].map { title in
            let book = row(app, title)
            return book.exists ? book.label : "\(title): no row"
        }
        sleep(2)
        capture("iphone-1-library")

        mars.tap()
        XCTAssertTrue(app.descendants(matching: .any)["bookDetail"].waitForExistence(timeout: 5)
                      || app.navigationBars["The Gods of Mars"].waitForExistence(timeout: 5), "book details did not open")
        sleep(2)
        capture("iphone-2-book-details")

        app.tabBars.buttons["Reading"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["typographyPreview"].waitForExistence(timeout: 10),
                      "Reading tab did not show its preview")
        sleep(2)
        capture("iphone-3-reading")

        // The full texts were read (sizes in KB, not bytes) and every book shows as on the watch.
        for label in labels {
            XCTAssertTrue(label.contains("On Apple Watch"), "book not shown on the watch: \(label)")
            XCTAssertFalse(label.contains("bytes"), "book seeded without its full text: \(label)")
        }
    }
}
