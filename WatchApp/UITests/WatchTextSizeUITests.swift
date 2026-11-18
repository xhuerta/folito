import XCTest

/// Build 48 feedback: a text size change in Reading Options keeps the passage that was at the top of the screen at
/// the top, in one clean move, and never changes the saved reading position (block and character offset). Uses the
/// long seeded book with the reader's position exposed (`-UITestingReaderPosition`). Runs with the other watch UI
/// tests (`accessibility.yml`, or a targeted run of `FolitoWatchUITests/WatchTextSizeUITests`).
final class WatchTextSizeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testTextSizeChangeKeepsTheFirstVisibleBlockAndThePosition() {
        let app = WatchUI.launch(seedSampleBook: true,
                                 extraArguments: ["-UITestingSeedLongBook", WatchUI.readerPositionArgument,
                                                  "-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        WatchUI.openReader(app)
        guard WatchUI.settledPosition(in: app, expected: (0, 0)) != nil else {
            return WatchUI.fail("The long book did not open at its start", in: app)
        }

        // At a chapter's start: the heading stays the first line.
        guard WatchUI.chooseChapter("Chapter 2", current: "Chapter 1", in: app) else { return }
        let heading = WatchUI.longBookHeadingIndex(chapter: 2)
        guard WatchUI.settledPosition(in: app, expected: (heading, 0)) != nil else {
            return WatchUI.fail("The jump to Chapter 2 did not settle at its heading", in: app)
        }
        changeTextSizeAndCheck(app, step: "at the chapter heading")
        XCTAssertTrue(WatchUI.firstVisibleBlock(in: app)?.label.hasPrefix("Chapter 2") == true
                      && WatchUI.firstVisibleBlock(in: app)?.label.contains(",") == false,
                      "the chapter heading should still be the first block below the bar")

        // Inside a paragraph: the same line, to the character.
        WatchUI.nudgeUp(app)
        WatchUI.nudgeUp(app)
        changeTextSizeAndCheck(app, step: "inside a paragraph")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "watch-text-size-kept"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Records the settled position and the first visible block, makes the text one point larger from Reading Options
    /// (its first row), closes the menu, and checks that both are unchanged and stay so.
    @MainActor
    private func changeTextSizeAndCheck(_ app: XCUIApplication, step: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        // Let a scroll by hand come to rest first.
        sleep(1)
        // The first visible block is measured below the shown bar (as after the menu closes); a tap shows the bar
        // for only 3 s, so it is read right away, and `openReaderMenu` reveals the bar again if it hid meanwhile.
        WatchUI.showReaderBar(app)
        let firstBefore = WatchUI.firstVisibleBlock(in: app)?.label
        guard let before = WatchUI.settledPosition(in: app) else {
            return WatchUI.fail("\(step): the reader did not settle", in: app, file: file, line: line)
        }

        WatchUI.openReaderMenu(app, file: file, line: line)
        let stepper = WatchUI.element("textSizeStepper", in: app)
        let sizeBefore = stepper.value as? String
        // The + button at the stepper's trailing end (the − and + are hidden from accessibility; the stepper is one
        // adjustable element).
        stepper.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let changed = NSPredicate { _, _ in (stepper.value as? String) != sizeBefore }
        guard XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)], timeout: 5) == .completed else {
            return WatchUI.fail("\(step): the text size did not change (\(sizeBefore ?? "?"))", in: app, file: file, line: line)
        }
        guard WatchUI.closeSheet(app, file: file, line: line) else { return }

        guard let after = WatchUI.settledPosition(in: app) else {
            return WatchUI.fail("\(step): the reader did not settle after the text size change", in: app, file: file, line: line)
        }
        XCTAssertEqual(after, before, "\(step): the reading position changed with the text size", file: file, line: line)
        let first = WatchUI.firstVisibleBlock(in: app)
        XCTAssertEqual(first?.label, firstBefore, "\(step): another block is at the top after the text size change",
                       file: file, line: line)
        // One move: nothing shifts once the text is shown again.
        let landed = first?.frame.minY
        sleep(2)
        if let first, let landed {
            XCTAssertEqual(first.frame.minY, landed, accuracy: 1, "\(step): the text moved again after the change",
                           file: file, line: line)
        }
        XCTAssertEqual(WatchUI.readerPosition(in: app).value as? String, before,
                       "\(step): the position was re-saved after the change", file: file, line: line)
    }
}
