import XCTest

/// Covers in the Library and the book detail screen (`-UITestingSeedCovers`, Debug builds only: the sample book
/// without a cover, plus two books with generated covers, a series and a description). Every state is attached
/// as a screenshot; macos.yml exports them as the `covers-iphone` artifact.
final class CoversUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestingSeedCovers"] + extra
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
    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'libraryRow' AND label BEGINSWITH %@", title)).firstMatch
    }

    /// Drags the screen up until `element` is hittable (List rows below the fold are not in the tree).
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
    private func openDetail(_ app: XCUIApplication, _ title: String) {
        let target = row(app, title)
        XCTAssertTrue(scrollTo(target, in: app), "\(title) row not reachable")
        target.tap()
        XCTAssertTrue(app.descendants(matching: .any)["bookDetail"].waitForExistence(timeout: 5)
                      || app.navigationBars[title].waitForExistence(timeout: 5), "Detail of \(title) did not open")
        sleep(1)
    }

    @MainActor
    func testCoversAtDefaultTextSize() throws {
        let app = launch()
        let mars = row(app, "The Gods of Mars")
        XCTAssertTrue(scrollTo(mars, in: app), "seeded books missing")
        sleep(1)
        screenshot(app, "covers-1-library")
        // The sample book has no cover: the generated placeholder.
        XCTAssertTrue(scrollTo(row(app, "Alice"), in: app), "cover-less sample book missing")
        screenshot(app, "covers-2-library-placeholder")

        openDetail(app, "The Gods of Mars")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Barsoom'")).firstMatch.exists,
                      "series line missing")
        screenshot(app, "covers-3-detail")
        let more = app.buttons["bookDescriptionMore"]
        XCTAssertTrue(scrollTo(more, in: app), "More button missing")
        screenshot(app, "covers-4-detail-description")
        more.tap()
        sleep(1)
        screenshot(app, "covers-5-detail-more")
        // Actions are still there at the bottom.
        XCTAssertTrue(scrollTo(app.buttons["bookDetailDelete"], in: app), "Delete action missing")
        screenshot(app, "covers-6-detail-actions")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        openDetail(app, "Alice")
        screenshot(app, "covers-7-detail-placeholder")
    }

    @MainActor
    func testCoversAtLargestTextSize() throws {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let mars = row(app, "The Gods of Mars")
        XCTAssertTrue(scrollTo(mars, in: app), "seeded books missing")
        sleep(1)
        screenshot(app, "covers-8-library-ax5")
        openDetail(app, "The Gods of Mars")
        screenshot(app, "covers-9-detail-ax5")
        let more = app.buttons["bookDescriptionMore"]
        if scrollTo(more, in: app, steps: 14) { screenshot(app, "covers-10-detail-ax5-description") }
    }
}
