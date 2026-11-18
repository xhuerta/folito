import XCTest

/// The chapter list on its own screen (#172): Reading Options has one row, "Chapters, <current chapter>", that
/// pushes the list; the list marks the current chapter as selected (screenshot `watch-chapters` attached to the
/// result), and a tap on a chapter closes the menu and returns to the text. Runs with the other watch UI tests
/// (`accessibility.yml`, or a targeted run of `FolitoWatchUITests/WatchChaptersUITests`).
final class WatchChaptersUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testChaptersRowOpensTheListAndAChapterClosesTheMenu() {
        let app = WatchUI.launch(seedSampleBook: true, extraArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        WatchUI.openReader(app)
        WatchUI.openReaderMenu(app)
        // The chapters no longer sit inline in the sheet: no chapter button before the row is opened.
        XCTAssertFalse(WatchUI.element("chapterButton", in: app).exists, "the sheet should not list the chapters inline")

        guard WatchUI.openChapters(app) else { return }
        let chapter = WatchUI.element("chapterButton", in: app)
        XCTAssertTrue(chapter.isHittable, "the list should open on the current chapter")
        XCTAssertTrue(chapter.label.contains(WatchUI.sampleChapter), "Chapter label: \(chapter.label)")
        XCTAssertTrue(chapter.isSelected, "the current chapter carries the selected trait")
        XCTAssertFalse(WatchUI.element("textSizeStepper", in: app).exists, "the list is its own screen")
        sleep(1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "watch-chapters"
        shot.lifetime = .keepAlways
        add(shot)

        chapter.tap()
        XCTAssertTrue(WatchUI.element("readerOptionsButton", in: app).waitForExistence(timeout: 5),
                      "Choosing a chapter should close the menu and show the book")
        XCTAssertFalse(chapter.exists, "the chapter list is gone with the menu")
        XCTAssertTrue(WatchUI.element("readerBlock", in: app).exists, "the book text shows again")
    }

    /// A jump to the last chapter of a long book (#174) is a far jump in the lazy reader: the text is covered
    /// while the scroll settles and is revealed with the chapter's heading at the top of the screen, where it
    /// then stays (no late correction moves it). Screenshot `watch-chapter-jump` attached to the result.
    @MainActor
    func testJumpToALateChapterShowsItsHeadingAtTheTop() {
        let app = WatchUI.launch(seedSampleBook: true,
                                 extraArguments: ["-UITestingSeedLongBook", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        WatchUI.openReader(app)
        WatchUI.openReaderMenu(app)
        guard WatchUI.openChapters(app, currentChapter: "Chapter 1") else { return }

        // The long book's last chapter (UITesting.longBookChapters in the app).
        let target = "Chapter 10"
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "chapterButton", target)).element(boundBy: 0)
        guard WatchUI.scrollToHittable(row, in: app, maxSteps: 24) else {
            WatchUI.fail("\(target) is not reachable in the chapter list", in: app)
            return
        }
        row.tap()
        XCTAssertTrue(WatchUI.element("readerOptionsButton", in: app).waitForExistence(timeout: 5),
                      "Choosing a chapter should close the menu and show the book")

        // The text is hidden from accessibility while the jump settles: the heading appears once it has landed.
        let heading = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@ AND NOT (label CONTAINS %@)",
                                  "readerBlock", target, "paragraph")).element(boundBy: 0)
        guard heading.waitForExistence(timeout: 10) else {
            WatchUI.fail("The heading of \(target) is not on screen after the jump", in: app)
            return
        }
        let window = app.windows.firstMatch.frame
        let landed = heading.frame
        XCTAssertGreaterThanOrEqual(landed.minY, window.minY - 1, "the heading is cut off at the top: \(landed)")
        XCTAssertLessThan(landed.minY, window.minY + window.height * 0.4,
                          "the heading should be at the top of the screen: \(landed) in \(window)")
        // Settled: nothing moves after the reveal.
        sleep(2)
        XCTAssertEqual(heading.frame.minY, landed.minY, accuracy: 1, "the text moved after it was revealed")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "watch-chapter-jump"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Build 48 feedback: choosing the next or the previous chapter must land exactly at its first line. In the long
    /// book (with the reader's position exposed, `-UITestingReaderPosition`) the next chapter, the one after it and
    /// then the previous one each end with the chapter's heading as the reading position (block of the heading,
    /// character offset 0), the heading as the first block below the bar, not cut by it, and nothing moving or
    /// being re-saved afterwards.
    @MainActor
    func testNextAndPreviousChapterLandAtTheChapterStart() {
        let app = WatchUI.launch(seedSampleBook: true,
                                 extraArguments: ["-UITestingSeedLongBook", WatchUI.readerPositionArgument,
                                                  "-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        WatchUI.openReader(app)
        guard WatchUI.settledPosition(in: app, expected: (0, 0)) != nil else {
            return WatchUI.fail("The long book did not open at its start", in: app)
        }

        // Next chapter from the start of chapter 1.
        guard WatchUI.chooseChapter("Chapter 2", current: "Chapter 1", in: app) else { return }
        assertLandedAtStart(of: 2, in: app, step: "next chapter")

        // Read a little into chapter 2, then the next chapter again.
        WatchUI.nudgeUp(app)
        WatchUI.nudgeUp(app)
        guard WatchUI.chooseChapter("Chapter 3", current: "Chapter 2", in: app) else { return }
        assertLandedAtStart(of: 3, in: app, step: "next chapter, from inside a chapter")

        // Read a little into chapter 3, then the previous chapter.
        WatchUI.nudgeUp(app)
        WatchUI.nudgeUp(app)
        guard WatchUI.chooseChapter("Chapter 2", current: "Chapter 3", in: app) else { return }
        assertLandedAtStart(of: 2, in: app, step: "previous chapter")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "watch-chapter-previous"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The reader settled at chapter `chapter`'s heading (position and screen), and stays there.
    @MainActor
    private func assertLandedAtStart(of chapter: Int, in app: XCUIApplication, step: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let index = WatchUI.longBookHeadingIndex(chapter: chapter)
        guard let settled = WatchUI.settledPosition(in: app, expected: (index, 0)) else {
            let value = WatchUI.readerPosition(in: app).value as? String ?? "none"
            WatchUI.fail("\(step): the position is \(value), not the start of Chapter \(chapter) (block=\(index) offset=0)",
                         in: app, file: file, line: line)
            return
        }
        let heading = WatchUI.headingBlock("Chapter \(chapter)", in: app)
        guard heading.waitForExistence(timeout: 5) else {
            WatchUI.fail("\(step): the heading of Chapter \(chapter) is not on screen", in: app, file: file, line: line)
            return
        }
        let options = WatchUI.element("readerOptionsButton", in: app)
        let window = app.windows.firstMatch.frame
        let landed = heading.frame
        if options.exists {
            XCTAssertGreaterThanOrEqual(landed.minY, options.frame.maxY - 1,
                                        "\(step): the heading is under the top bar: \(landed), bar button \(options.frame)",
                                        file: file, line: line)
        }
        XCTAssertLessThan(landed.minY, window.minY + window.height * 0.4,
                          "\(step): the heading should be at the top of the screen: \(landed) in \(window)",
                          file: file, line: line)
        XCTAssertEqual(WatchUI.firstVisibleBlock(in: app)?.label, heading.label,
                       "\(step): the first block below the bar should be the chapter heading", file: file, line: line)
        // Settled: nothing moves and the position is not re-saved after the reveal.
        sleep(2)
        XCTAssertEqual(heading.frame.minY, landed.minY, accuracy: 1, "\(step): the text moved after it was revealed",
                       file: file, line: line)
        XCTAssertEqual(WatchUI.readerPosition(in: app).value as? String, settled,
                       "\(step): the position changed after landing", file: file, line: line)
    }
}
