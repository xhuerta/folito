import XCTest

/// Bookmarks in the reader menu (#65): "Add Bookmark" marks the line at the top of the screen and turns into
/// "Bookmarked", the bookmark list shows it (screenshot `watch-bookmarks` attached to the result), and a tap on
/// it closes the menu and returns to the text. Runs with the other watch UI tests (`accessibility.yml`, or a
/// targeted run of `FolitoWatchUITests/WatchBookmarksUITests`).
final class WatchBookmarksUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testAddListAndOpenABookmark() {
        let app = WatchUI.launch(seedSampleBook: true, extraArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        WatchUI.openReader(app)
        WatchUI.openReaderMenu(app)

        let addButton = WatchUI.element("addBookmarkButton", in: app)
        guard WatchUI.scrollToHittable(addButton, in: app) else {
            return WatchUI.fail("The reader menu did not offer Add Bookmark", in: app)
        }
        XCTAssertEqual(addButton.label, "Add Bookmark")
        addButton.tap()
        let bookmarked = NSPredicate(format: "label == %@", "Bookmarked")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: bookmarked, object: addButton)], timeout: 5),
                       .completed, "Add Bookmark should turn into Bookmarked. Tree:\n\(app.debugDescription)")
        XCTAssertFalse(addButton.isEnabled, "the line is bookmarked: the button is dimmed")

        // By identifier, or by its label: on watchOS a NavigationLink row may not carry the identifier set on it.
        let byID = WatchUI.element("bookmarksLink", in: app)
        let byLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "All Bookmarks")).element(boundBy: 0)
        WatchUI.scrollToHittable(byID.exists ? byID : byLabel, in: app, maxSteps: 4)
        let link = byID.exists && byID.isHittable ? byID : byLabel
        guard link.exists, link.isHittable else { return WatchUI.fail("All Bookmarks is not reachable", in: app) }
        link.tap()

        let row = WatchUI.element("bookmarkRow", in: app)
        guard row.waitForExistence(timeout: 5) else { return WatchUI.fail("The bookmark list shows no bookmark", in: app) }
        XCTAssertTrue(row.label.contains("%"), "the row reads its place in the book: \(row.label)")
        sleep(1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "watch-bookmarks"
        shot.lifetime = .keepAlways
        add(shot)

        row.tap()
        XCTAssertTrue(WatchUI.element("readerOptionsButton", in: app).waitForExistence(timeout: 5),
                      "Opening a bookmark should close the menu and show the book")
        XCTAssertFalse(row.exists, "the bookmark list is gone with the menu")
    }
}
