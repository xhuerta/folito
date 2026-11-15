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
}
