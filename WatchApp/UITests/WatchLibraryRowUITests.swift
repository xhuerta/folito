import XCTest

/// The Library row follows the book's read status: "Mark as Finished" in the reader menu turns the row's progress
/// ("0% read") into "Finished" once back in the Library, and "Mark as Unread" turns it back. Guards against the
/// row not being redrawn because `LibraryEntry`'s `==` compares only hash and title. Runs with the other watch
/// UI tests (`accessibility.yml`, or a targeted run of `FolitoWatchUITests/WatchLibraryRowUITests`).
final class WatchLibraryRowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testRowFollowsReadStatus() {
        let app = WatchUI.launch(seedSampleBook: true, extraArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        let row = WatchUI.libraryRow(in: app)
        XCTAssertTrue(row.label.contains("read"), "A new book shows its progress: \(row.label)")
        XCTAssertFalse(row.label.contains("Finished"), "A new book is not finished: \(row.label)")

        toggleReadStatus(app, expecting: "Mark as Finished")
        assertRow(app, finished: true)

        toggleReadStatus(app, expecting: "Mark as Unread")
        assertRow(app, finished: false)
    }

    /// Library -> reader -> Reading Options -> the read status button (labelled `expecting`) -> back to the Library.
    @MainActor
    private func toggleReadStatus(_ app: XCUIApplication, expecting label: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        WatchUI.openReader(app, file: file, line: line)
        WatchUI.openReaderMenu(app, file: file, line: line)
        let button = WatchUI.element("readStatusButton", in: app)
        guard WatchUI.scrollToHittable(button, in: app) else {
            return WatchUI.fail("The reader menu did not offer the read status button", in: app, file: file, line: line)
        }
        XCTAssertEqual(button.label, label, file: file, line: line)
        button.tap()
        let flipped = NSPredicate(format: "label != %@", label)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: flipped, object: button)], timeout: 5),
                       .completed, "\(label) should toggle the button", file: file, line: line)
        WatchUI.closeSheet(app, file: file, line: line)

        let back = WatchUI.element("BackButton", in: app)
        if !WatchUI.waitForHittable(back, timeout: 5) {
            // The bar hid: a tap on the text shows it again.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        }
        XCTAssertTrue(WatchUI.waitForHittable(back, timeout: 5), "The back button should show", file: file, line: line)
        back.tap()
        XCTAssertTrue(WatchUI.waitForHittable(WatchUI.libraryRow(in: app), timeout: 10),
                      "Did not return to the Library", file: file, line: line)
    }

    /// The row reads "…, Finished" (and has the `finishedLabel` part, when the tree shows it) or "…, N% read".
    @MainActor
    private func assertRow(_ app: XCUIApplication, finished: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let row = WatchUI.libraryRow(in: app)
        let wanted = finished
            ? NSPredicate(format: "label CONTAINS %@", "Finished")
            : NSPredicate(format: "label CONTAINS %@ AND NOT (label CONTAINS %@)", "% read", "Finished")
        // A short wait: the row is redrawn when the Library shows again, or never.
        if XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: wanted, object: row)], timeout: 5) != .completed {
            return WatchUI.fail("The Library row should read \(finished ? "Finished" : "its progress"): \(row.label)",
                                in: app, file: file, line: line)
        }
        let finishedLabel = WatchUI.element("finishedLabel", in: app)
        if !finished {
            XCTAssertFalse(finishedLabel.exists, "No Finished label on an unread book", file: file, line: line)
        }
    }
}
