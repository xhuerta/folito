import XCTest

/// The Readest library in the Library tab, with a mocked Readest account (`-UITestingMockReadest`, Debug builds
/// only): cloud-only rows, a download in progress, the context menus, the filter menu, the offline state and the
/// Readest section of Progress Sync. Every state is attached as a screenshot (macos.yml exports them as the
/// `readest-library-screenshots` artifact).
final class ReadestLibraryUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestingSeedSampleBook", "-UITestingMockReadest"] + extra
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
    private func cloudRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'libraryCloudRow' AND label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor
    func testLibraryStatesScreenshots() throws {
        let app = launch()
        let row = cloudRow(app, "Pride and Prejudice")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "cloud-only book missing")
        XCTAssertTrue(row.value as? String == "In Readest, not downloaded", "value: \(String(describing: row.value))")
        let local = app.descendants(matching: .any)["libraryRow"]
        XCTAssertTrue(local.label.contains("In Readest"), "local row should say it is in Readest: \(local.label)")
        sleep(1) // covers
        screenshot(app, "readest-1-library")

        // Context menu of a local book that is also in Readest.
        local.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Remove Download"].waitForExistence(timeout: 5))
        screenshot(app, "readest-2-context-menu-local")
        app.buttons["Remove Download"].firstMatch.tap()
        XCTAssertTrue(cloudRow(app, "Alice").waitForExistence(timeout: 5), "removed download should become cloud-only")
        screenshot(app, "readest-3-removed-download")

        // Context menu of a cloud-only book.
        cloudRow(app, "The Time Machine").press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Delete from Readest"].waitForExistence(timeout: 5))
        screenshot(app, "readest-4-context-menu-cloud")
        app.buttons["Download"].firstMatch.tap()

        // Download in progress (the mock stops at 45 %).
        let downloading = cloudRow(app, "The Time Machine")
        let started = NSPredicate(format: "value BEGINSWITH 'Downloading'")
        expectation(for: started, evaluatedWith: downloading)
        waitForExpectations(timeout: 5)
        sleep(2)
        screenshot(app, "readest-5-downloading")

        // Filter menu.
        app.buttons["libraryFilterMenu"].tap()
        XCTAssertTrue(app.buttons["In Readest"].waitForExistence(timeout: 5))
        screenshot(app, "readest-6-filter-menu")
        app.buttons["On This iPhone"].tap()
        XCTAssertFalse(cloudRow(app, "Pride and Prejudice").waitForExistence(timeout: 2), "filter should hide cloud-only books")
        screenshot(app, "readest-7-filter-on-iphone")
        app.buttons["libraryFilterMenu"].tap()
        app.buttons["All"].tap()

        // Settings › Progress Sync › Readest Library.
        app.tabBars.buttons["Settings"].tap()
        app.descendants(matching: .any)["syncSettingsLink"].tap()
        XCTAssertTrue(app.navigationBars["Progress Sync"].waitForExistence(timeout: 5))
        let toggle = app.switches["readestAutoUpload"]
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.exists, "automatic upload toggle missing")
        XCTAssertEqual(toggle.value as? String, "0", "automatic upload must be off by default")
        sleep(1)
        screenshot(app, "readest-8-settings")
    }

    @MainActor
    func testOfflineScreenshot() throws {
        let app = launch(["-UITestingReadestOffline"])
        let row = cloudRow(app, "Frankenstein")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue((row.value as? String)?.contains("connection") == true, "offline value: \(String(describing: row.value))")
        app.swipeUp()
        sleep(1)
        screenshot(app, "readest-9-offline")
    }

    @MainActor
    func testLargestTextScreenshot() throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(cloudRow(app, "Pride and Prejudice").waitForExistence(timeout: 10))
        screenshot(app, "readest-10-largest-text")
    }
}
