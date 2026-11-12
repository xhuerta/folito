import XCTest

/// The reader's top bar (#106): it hides while scrolling down through the text, a tap on the text brings it
/// back (without opening the word picker). The left-edge swipe back is tracked in #118. Runs with the watch
/// accessibility UI tests (`accessibility.yml`); the hidden-bar screenshot is attached to the result to show
/// what watchOS keeps on screen (the system time).
///
/// The book is the App Store seed's *Pride and Prejudice* opening (`-UITestingSeedAppStore`, the newest and
/// first Library row, opened at its start): the one-paragraph sample book (`-UITestingSeedSampleBook`) is
/// shorter than a screen and a half, so it can scroll only about 50 pt, which stays within
/// `BarAutoHide.minHideOffset` (the start of the book, where the bar never hides).
final class WatchReaderTopBarTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, hittable: Bool, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate { _, _ in (element.exists && element.isHittable) == hittable }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    func testBarHidesOnScrollAndReturnsOnTap() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestingSeedAppStore", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(WatchUI.libraryRow(in: app).waitForExistence(timeout: 45), "Library screen did not appear")
        WatchUI.openReader(app)
        let options = WatchUI.element("readerOptionsButton", in: app)
        XCTAssertTrue(waitFor(options, hittable: true), "Reading Options button should show when the book opens")

        for _ in 0..<3 { WatchUI.nudgeUp(app) }
        XCTAssertTrue(waitFor(options, hittable: false),
                      "The top bar should hide after scrolling down. Tree:\n\(app.debugDescription)")
        sleep(1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "watch-reader-bar-hidden"
        shot.lifetime = .keepAlways
        add(shot)

        // A tap on the text shows the bar again instead of opening the word picker.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        XCTAssertTrue(waitFor(options, hittable: true), "A tap on the text should show the top bar")
        let nextWord = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Next Word"))
            .element(boundBy: 0)
        XCTAssertFalse(nextWord.exists, "The tap that shows the bar must not open the word picker")
        // The left-edge swipe back is tracked in #118: it does not leave the reader yet, with or without
        // the bar hidden, so it is not asserted here.
    }

    /// The text block under a point 30% down the screen, below the navigation bar: the block being read.
    @MainActor
    private func blockAtReadingLine(_ app: XCUIApplication) -> String? {
        let window = app.windows.firstMatch.frame
        let y = window.minY + window.height * 0.3
        let blocks = app.descendants(matching: .any).matching(identifier: "readerBlock").allElementsBoundByIndex
        return blocks.first { $0.frame.minY <= y && $0.frame.maxY > y }?.label
    }

    /// Reopening a book (#125): it opens at the saved line with the bar visible, and nothing moves after
    /// that. Before the fix the in-block restore scrolled the text again 0.7 s after it appeared, and that
    /// programmatic scroll hid the bar.
    @MainActor
    func testReopeningKeepsTheBarAndTheSavedLine() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestingSeedAppStore", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(WatchUI.libraryRow(in: app).waitForExistence(timeout: 45), "Library screen did not appear")
        WatchUI.openReader(app)
        let options = WatchUI.element("readerOptionsButton", in: app)
        XCTAssertTrue(waitFor(options, hittable: true), "Reading Options button should show when the book opens")

        // Read on a little (into a paragraph, so the saved position has an in-block offset), then leave.
        for _ in 0..<3 { WatchUI.nudgeUp(app) }
        sleep(2)
        guard let saved = blockAtReadingLine(app) else {
            return WatchUI.fail("No text block at the reading line before leaving", in: app)
        }
        if !options.isHittable {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        }
        let back = WatchUI.element("BackButton", in: app)
        XCTAssertTrue(waitFor(back, hittable: true), "The back button should show. Tree:\n\(app.debugDescription)")
        back.tap()
        XCTAssertTrue(waitFor(WatchUI.libraryRow(in: app), hittable: true, timeout: 10), "Did not return to the Library")

        WatchUI.openReader(app)
        XCTAssertTrue(waitFor(options, hittable: true), "The top bar should be visible when the book reopens")
        let opened = blockAtReadingLine(app)
        sleep(3) // longer than any restore check: nothing may move or hide after the first frame
        XCTAssertTrue(options.isHittable, "The top bar hid by itself after reopening. Tree:\n\(app.debugDescription)")
        XCTAssertEqual(opened, saved, "The book should reopen at the block it was left at")
        XCTAssertEqual(blockAtReadingLine(app), opened, "The text moved after the book appeared")
    }
}
