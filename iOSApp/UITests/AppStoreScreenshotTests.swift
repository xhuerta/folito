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

    /// Waits up to `timeout` seconds for `element`; on a timeout fails the test with `message`, a screenshot
    /// (attachment "failure screen") and the accessibility tree. The timeouts are generous: on a busy CI runner
    /// the first launch on a just-booted simulator has taken over a minute.
    @MainActor
    private func require(_ element: XCUIElement, _ timeout: TimeInterval, _ message: String,
                         in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        if element.waitForExistence(timeout: timeout) { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "failure screen"
        shot.lifetime = .keepAlways
        XCTContext.runActivity(named: message) { $0.add(shot) }
        XCTFail("\(message) (waited \(Int(timeout)) s). Tree:\n\(app.debugDescription)", file: file, line: line)
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
        require(app.navigationBars["Library"], 60, "Library screen did not appear", in: app)
        let mars = row(app, "The Gods of Mars")
        require(mars, 30, "seeded books missing", in: app)
        // Checked at the end, so that a wrong Library still yields all three captures to look at.
        let labels = ["The Gods of Mars", "Emma", "Alice"].map { title in
            let book = row(app, title)
            return book.exists ? book.label : "\(title): no row"
        }
        sleep(2)
        capture("iphone-1-library")

        mars.tap()
        if !app.descendants(matching: .any)["bookDetail"].waitForExistence(timeout: 20) {
            require(app.navigationBars["The Gods of Mars"], 5, "book details did not open", in: app)
        }
        sleep(2)
        capture("iphone-2-book-details")

        let readingTab = app.tabBars.buttons["Reading"]
        require(readingTab, 20, "Reading tab button missing", in: app)
        readingTab.tap()
        require(app.descendants(matching: .any)["typographyPreview"], 30, "Reading tab did not show its preview", in: app)
        sleep(2)
        capture("iphone-3-reading")

        // The full texts were read (sizes in KB, not bytes) and every book shows as on the watch.
        for label in labels {
            XCTAssertTrue(label.contains("On Apple Watch"), "book not shown on the watch: \(label)")
            XCTAssertFalse(label.contains("bytes"), "book seeded without its full text: \(label)")
        }
    }
}
