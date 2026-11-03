import XCTest

/// The welcome tour: walks through every page, adds the sample book and finds it in the Library; Skip; reopening
/// from Settings. Each page is attached as a screenshot (kept in the .xcresult; macos.yml exports them as the
/// `onboarding-screenshots` artifact), at the default text size and at the largest accessibility size.
final class OnboardingUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launchWithTour(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // -UITesting: an empty, throw-away library; -UITestingShowOnboarding: open the tour (Debug builds only).
        app.launchArguments += ["-UITesting", "-UITestingShowOnboarding"] + extraArguments
        app.launch()
        XCTAssertTrue(app.staticTexts["onboardingTitle"].waitForExistence(timeout: 15), "Welcome tour did not appear")
        return app
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The current page's title (every page title has the identifier "onboardingTitle").
    @MainActor
    private func waitForPage(_ app: XCUIApplication, title: String) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "identifier == 'onboardingTitle' AND label == %@", title))
            .firstMatch.waitForExistence(timeout: 5)
    }

    /// Taps a button, scrolling down first if it is below the fold (at accessibility text sizes the
    /// navigation buttons follow the page content).
    @MainActor
    private func tapScrolling(_ app: XCUIApplication, _ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(identifier) missing")
        var swipes = 0
        while !button.isHittable && swipes < 12 {
            app.swipeUp()
            swipes += 1
        }
        button.tap()
    }

    @MainActor
    private func tapContinue(_ app: XCUIApplication) {
        tapScrolling(app, "onboardingContinue")
    }

    @MainActor
    private func walkThrough(_ app: XCUIApplication, prefix: String) {
        XCTAssertTrue(waitForPage(app, title: "Welcome to Folito"))
        screenshot(app, "\(prefix)-1-welcome")
        tapContinue(app)

        XCTAssertTrue(waitForPage(app, title: "How It Works"))
        screenshot(app, "\(prefix)-2-how-it-works")
        tapContinue(app)

        XCTAssertTrue(waitForPage(app, title: "Try It Now"))
        let addSample = app.buttons["onboardingAddSample"]
        XCTAssertTrue(addSample.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["onboardingImportOwn"].exists)
        tapScrolling(app, "onboardingAddSample")
        let result = app.descendants(matching: .any)["onboardingImportResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 30), "The sample book was not added")
        XCTAssertTrue(result.label.contains("Pride and Prejudice"), "Unexpected result: \(result.label)")
        screenshot(app, "\(prefix)-3-try-it")
        tapContinue(app)

        XCTAssertTrue(waitForPage(app, title: "Optional Extras"))
        XCTAssertTrue(app.buttons["onboardingDictionaries"].exists)
        XCTAssertTrue(app.buttons["onboardingSync"].exists)
        screenshot(app, "\(prefix)-4-extras")
        app.swipeUp()
        screenshot(app, "\(prefix)-4-extras-bottom")
        tapScrolling(app, "onboardingDone")
    }

    @MainActor
    func testWalkThroughAddsSampleBook() throws {
        let app = launchWithTour()
        walkThrough(app, prefix: "default")

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5), "Library did not appear after the tour")
        let row = app.descendants(matching: .any)["libraryRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Sample book not in the Library")
        XCTAssertTrue(row.label.contains("Pride and Prejudice"), "Row: \(row.label)")
        XCTAssertTrue(row.label.contains("Sample"), "Row should carry the Sample badge: \(row.label)")
        screenshot(app, "default-5-library")
    }

    /// Same pages at the largest accessibility text size (screenshots only; the flow must still work).
    @MainActor
    func testWalkThroughAtLargestTextSize() throws {
        let app = launchWithTour(extraArguments: ["-UIPreferredContentSizeCategoryName",
                                                  "UICTContentSizeCategoryAccessibilityXXXL"])
        walkThrough(app, prefix: "axxxl")
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSkipClosesTheTour() throws {
        let app = launchWithTour()
        app.buttons["onboardingSkip"].tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["onboardingTitle"].exists)
    }

    @MainActor
    func testReopenFromSettings() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITesting"]
        app.launch()
        // UI-testing launches skip the tour unless asked for it.
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["onboardingTitle"].exists)

        app.tabBars.buttons["Settings"].tap()
        let button = app.buttons["showWelcomeTour"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(app.staticTexts["onboardingTitle"].waitForExistence(timeout: 5))
        app.buttons["onboardingSkip"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    /// The empty Library offers the sample book too (for App Review and anyone who skipped the tour).
    @MainActor
    func testLibraryEmptyStateAddsSample() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITesting"]
        app.launch()
        let button = app.buttons["libraryAddSample"]
        XCTAssertTrue(button.waitForExistence(timeout: 15))
        button.tap()
        let row = app.descendants(matching: .any)["libraryRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "Sample book not added from the Library")
        XCTAssertTrue(row.label.contains("Sample"), "Row: \(row.label)")
    }
}
