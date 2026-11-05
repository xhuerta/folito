import XCTest

/// Optional online lookup of missing details (docs/ONLINE_METADATA.md) with a mocked Open Library
/// (`-UITestingMockOnlineMetadata`, Debug builds only; no network): Settings › Book Details, the detail screen's
/// *Find Details Online*, the confirmation sheet (one match, several, none, offline) and *Remove Online Details*.
/// Every state is attached as a screenshot; macos.yml exports them as the `online-metadata-screenshots` artifact.
final class OnlineMetadataUITests: XCTestCase {
    private static let alice = "Alice"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestingSeedSampleBook", "-UITestingMockOnlineMetadata"] + extra
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
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor
    @discardableResult
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, steps: Int = 10) -> Bool {
        for _ in 0..<steps where !(element.exists && element.isHittable) {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func openDetail(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'libraryRow' AND label BEGINSWITH %@", Self.alice)).firstMatch
        XCTAssertTrue(scrollTo(row, in: app), "Sample book row not reachable")
        row.tap()
        XCTAssertTrue(element(app, "bookDetail").waitForExistence(timeout: 5), "Detail did not open")
    }

    @MainActor
    private func openSheet(_ app: XCUIApplication) {
        openDetail(app)
        let find = app.buttons["bookDetailFindOnline"]
        XCTAssertTrue(scrollTo(find, in: app), "Find Details Online missing")
        find.tap()
    }

    // MARK: Settings

    @MainActor
    func testSettingsBookDetailsAndBulkLookup() throws {
        let app = launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let toggle = app.switches["onlineAutoLookupToggle"]
        XCTAssertTrue(scrollTo(toggle, in: app), "Find Missing Details Online toggle missing")
        XCTAssertEqual(toggle.value as? String, "0", "the lookup must be off by default")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Open Library'")).firstMatch.exists,
                      "the footer must say who receives the request")
        screenshot(app, "online-1-settings")

        let start = app.buttons["onlineBulkStart"]
        XCTAssertTrue(scrollTo(start, in: app))
        start.tap()
        let summary = element(app, "onlineBulkSummary")
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "no summary after the lookup")
        XCTAssertTrue(summary.label.contains("1"), "summary: \(summary.label)")
        screenshot(app, "online-2-settings-summary")

        // The sample book now has Open Library's cover and description, marked as such; removing them reverts.
        app.tabBars.buttons["Library"].tap()
        openDetail(app)
        XCTAssertTrue(element(app, "onlineCoverCaption").waitForExistence(timeout: 5), "cover caption missing")
        screenshot(app, "online-3-detail-with-online-details")
        let remove = app.buttons["bookDetailRemoveOnline"]
        XCTAssertTrue(scrollTo(remove, in: app), "Remove Online Details missing")
        screenshot(app, "online-4-detail-actions")
        remove.tap()
        XCTAssertFalse(element(app, "onlineCoverCaption").waitForExistence(timeout: 2), "online cover not removed")
        XCTAssertFalse(app.buttons["bookDetailRemoveOnline"].exists)
    }

    // MARK: Find Details Online

    @MainActor
    func testFindDetailsOnlineConfirmation() throws {
        let app = launch()
        openSheet(app)
        XCTAssertTrue(element(app, "onlineMatchReview").waitForExistence(timeout: 10), "match not shown")
        let useCover = app.buttons["onlineUseCover"]
        XCTAssertTrue(useCover.waitForExistence(timeout: 5), "Use This Cover missing")
        XCTAssertTrue(app.buttons["onlineUseDescription"].exists, "Use Description must be a separate action")
        screenshot(app, "online-5-sheet-match")
        // Nothing is applied before confirming.
        useCover.tap()
        XCTAssertTrue(app.staticTexts["Cover Added"].waitForExistence(timeout: 5))
        let useDescription = app.buttons["onlineUseDescription"]
        XCTAssertTrue(scrollTo(useDescription, in: app))
        screenshot(app, "online-6-sheet-cover-added")
        useDescription.tap()
        XCTAssertTrue(app.staticTexts["Description Added"].waitForExistence(timeout: 5))
        app.buttons["onlineDone"].tap()

        XCTAssertTrue(element(app, "bookDescription").waitForExistence(timeout: 5), "description not applied")
        XCTAssertTrue(element(app, "onlineCoverCaption").exists, "cover not applied")
        XCTAssertTrue(app.staticTexts["From Open Library"].exists, "online description not marked")
        screenshot(app, "online-7-detail-after")
    }

    @MainActor
    func testSeveralMatches() throws {
        let app = launch(["-UITestingOnlineMetadataSeveral"])
        openSheet(app)
        let rows = app.descendants(matching: .any).matching(identifier: "onlineMatchRow")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "no match list")
        XCTAssertEqual(rows.count, 3)
        sleep(1)
        screenshot(app, "online-8-sheet-several")
        rows.firstMatch.tap()
        XCTAssertTrue(app.buttons["onlineUseCover"].waitForExistence(timeout: 5), "chosen match not shown")
        screenshot(app, "online-9-sheet-chosen")
    }

    @MainActor
    func testNoMatches() throws {
        let app = launch(["-UITestingOnlineMetadataEmpty"])
        openSheet(app)
        XCTAssertTrue(element(app, "onlineEmpty").waitForExistence(timeout: 10), "empty state missing")
        screenshot(app, "online-10-sheet-empty")
    }

    @MainActor
    func testOfflineShowsAClearMessage() throws {
        let app = launch(["-UITestingOnlineMetadataOffline"])
        openSheet(app)
        XCTAssertTrue(element(app, "onlineFailed").waitForExistence(timeout: 10), "error state missing")
        XCTAssertTrue(app.staticTexts["Couldn’t Reach Open Library"].exists)
        screenshot(app, "online-11-sheet-offline")
    }

    @MainActor
    func testLargestTextSize() throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        openSheet(app)
        XCTAssertTrue(element(app, "onlineMatchReview").waitForExistence(timeout: 10), "match not shown")
        sleep(1)
        screenshot(app, "online-12-sheet-ax5")
        if scrollTo(app.buttons["onlineUseCover"], in: app, steps: 14) { screenshot(app, "online-13-sheet-ax5-actions") }
    }
}
