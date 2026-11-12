import XCTest

/// The reader's top bar (#106): it hides while scrolling down through the text, a tap on the text brings it
/// back (without opening the word picker), and the left-edge swipe leaves the book. Runs with the watch
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
    func testBarHidesOnScrollReturnsOnTapAndEdgeSwipeLeaves() {
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

        // The left-edge swipe goes back to the Library.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(waitFor(WatchUI.libraryRow(in: app), hittable: true),
                      "The edge swipe should leave the reader. Tree:\n\(app.debugDescription)")
    }

    /// The left-edge swipe leaves the reader right after it opens, before the bar has ever hidden. Kept apart
    /// from the test above so a failure tells whether the swipe itself or the bar's hiding is at fault.
    @MainActor
    func testEdgeSwipeLeavesBeforeAnyScrolling() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestingSeedAppStore", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(WatchUI.libraryRow(in: app).waitForExistence(timeout: 45), "Library screen did not appear")
        WatchUI.openReader(app)
        XCTAssertTrue(waitFor(WatchUI.element("readerOptionsButton", in: app), hittable: true),
                      "Reading Options button should show when the book opens")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        XCTAssertTrue(waitFor(WatchUI.libraryRow(in: app), hittable: true),
                      "The edge swipe should leave the reader. Tree:\n\(app.debugDescription)")
    }
}
