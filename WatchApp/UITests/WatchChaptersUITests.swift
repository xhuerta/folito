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
}
