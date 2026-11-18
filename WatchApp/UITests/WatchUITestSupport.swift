import XCTest

/// Launch and navigation helpers shared by the watch UI tests. The app is launched with `-UITesting` (empty,
/// throw-away library, no WatchConnectivity) or `-UITestingSeedSampleBook` (one built-in sample book); both are
/// handled in Debug builds only, see WatchApp/Support/UITestingSupport.swift.
@MainActor
enum WatchUI {
    static let sampleTitle = "Alice’s Adventures in Wonderland"
    static let sampleChapter = "Down the Rabbit-Hole"

    /// Launch arguments that make the app start at the largest accessibility text size
    /// (`UIContentSizeCategory.accessibilityExtraExtraExtraLarge`).
    static let accessibilityXXXLArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    static func launch(seedSampleBook: Bool = false, extraArguments: [String] = [],
                       file: StaticString = #filePath, line: UInt = #line) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += seedSampleBook ? ["-UITestingSeedSampleBook"] : ["-UITesting"]
        app.launchArguments += extraArguments
        app.launch()
        let ready = seedSampleBook ? libraryRow(in: app) : emptyLibraryMessage(in: app)
        XCTAssertTrue(ready.waitForExistence(timeout: 20), "Library screen did not appear", file: file, line: line)
        return app
    }

    static func libraryRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "libraryRow").element(boundBy: 0)
    }

    /// The empty-state title. Matched by label because ContentUnavailableView may merge its title and
    /// description into one element.
    static func emptyLibraryMessage(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "No Books")).element(boundBy: 0)
    }

    static func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).element(boundBy: 0)
    }

    /// Library -> Settings.
    static func openSettings(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = element("settingsButton", in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Settings button missing", file: file, line: line)
        button.tap()
        XCTAssertTrue(element("textSizeStepper", in: app).waitForExistence(timeout: 5),
                      "Settings did not open (no text size stepper)", file: file, line: line)
    }

    /// Library (seeded) -> reader of the first book.
    ///
    /// The row exists as soon as the Library is in the accessibility tree, which on a freshly launched app can be
    /// before the list takes taps (launch transition, covers and progress loading into the rows): such a tap is
    /// dropped and the Library stays on screen. So the row is tapped again (up to three times) while it is still
    /// showing and hittable, and once the reader is on screen ("Opening…" while the book loads) the wait goes on
    /// without tapping, up to `timeout` seconds in all. On a timeout the failure says which screen was showing
    /// and attaches a screenshot.
    static func openReader(_ app: XCUIApplication, timeout: TimeInterval = 60,
                           file: StaticString = #filePath, line: UInt = #line) {
        let row = libraryRow(in: app)
        let text = element("readerBlock", in: app)
        let deadline = Date().addingTimeInterval(timeout)
        var taps = 0
        while Date() < deadline {
            if text.exists { return }
            if taps < 3, row.exists, row.isHittable {
                row.tap()
                taps += 1
                if text.waitForExistence(timeout: 8) { return }
            } else {
                _ = text.waitForExistence(timeout: 2)
            }
        }
        if text.exists { return }
        let opening = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Opening")).element(boundBy: 0)
        let state = row.exists && row.isHittable ? "the Library is still showing"
            : opening.exists ? "the reader still shows \u{201C}Opening\u{2026}\u{201D}"
            : "neither the Library nor the book text is showing"
        fail("Reader did not show the book text within \(Int(timeout)) s after \(taps) tap(s): \(state)",
             in: app, file: file, line: line)
    }

    /// Fails the test with `message`, a screenshot of the screen (attachment "failure screen") and the
    /// accessibility tree.
    static func fail(_ message: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "failure screen"
        shot.lifetime = .keepAlways
        XCTContext.runActivity(named: message) { $0.add(shot) }
        XCTFail("\(message). Tree:\n\(app.debugDescription)", file: file, line: line)
    }

    /// Reader -> Reading Options sheet (text size, dictionary, bookmarks, the Chapters row).
    ///
    /// The bar may be hidden (scrolled down) or about to hide again (a tap on the text shows it for only
    /// `BarAutoHide.tapRevealDuration`, 3 s, which a few slow queries on the watch can use up): the button is
    /// tapped as soon as it is hittable, and while it is not in the tree at all (bar hidden) the bar is revealed
    /// with a tap on the text (which opens nothing while the bar is hidden), up to three times.
    static func openReaderMenu(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = element("readerOptionsButton", in: app)
        var tapped = false
        for attempt in 0..<3 {
            if waitForHittable(button, timeout: attempt == 0 ? 5 : 3) {
                button.tap()
                tapped = true
                break
            }
            if button.exists {
                // Shown but not reported hittable (as before this helper waited for that): tap it anyway.
                button.tap()
                tapped = true
                break
            }
            // The bar is hidden (its button leaves the tree): a tap on the text shows it and opens nothing.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        }
        XCTAssertTrue(tapped, "Reading Options button missing", file: file, line: line)
        // The text size stepper is the sheet's first row; the Chapters row is further down and, in a lazy
        // List on a small watch, only enters the accessibility tree once scrolled into view.
        XCTAssertTrue(element("textSizeStepper", in: app).waitForExistence(timeout: 5),
                      "Reading Options did not open (no text size stepper)", file: file, line: line)
    }

    /// The Chapters row of Reading Options (#172), by identifier or by its label ("Chapters, <current chapter>"):
    /// on watchOS a NavigationLink row may not carry the identifier set on it. English label: callers launch in
    /// English.
    static func chaptersLink(in app: XCUIApplication) -> XCUIElement {
        let byID = element("chaptersLink", in: app)
        if byID.exists { return byID }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Chapters")).element(boundBy: 0)
    }

    /// Reading Options -> chapter list (#172): scrolls to the Chapters row (up to `maxSteps` small drags), checks
    /// that it reads the current chapter, taps it and waits for the list. Returns whether the list opened.
    @discardableResult
    static func openChapters(_ app: XCUIApplication, currentChapter: String = sampleChapter, maxSteps: Int = 12,
                             file: StaticString = #filePath, line: UInt = #line) -> Bool {
        var steps = 0
        while !(chaptersLink(in: app).exists && chaptersLink(in: app).isHittable) && steps < maxSteps {
            nudgeUp(app)
            steps += 1
        }
        let link = chaptersLink(in: app)
        guard link.exists, link.isHittable else {
            fail("Chapters row not reachable in Reading Options", in: app, file: file, line: line)
            return false
        }
        XCTAssertTrue(link.label.contains("Chapters"), "Chapters row label: \(link.label)", file: file, line: line)
        XCTAssertTrue(link.label.contains(currentChapter),
                      "The Chapters row should read the current chapter: \(link.label)", file: file, line: line)
        link.tap()
        guard element("chapterButton", in: app).waitForExistence(timeout: 5) else {
            fail("The chapter list did not open (no chapter button)", in: app, file: file, line: line)
            return false
        }
        return true
    }

    /// Settings or Reading Options -> Typography editor.
    static func openTypography(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        // By identifier, or by its label: on watchOS a NavigationLink row may not carry the identifier set on it.
        let byID = element("typographyLink", in: app)
        let byLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Typography")).element(boundBy: 0)
        var steps = 0
        while !(byID.exists && byID.isHittable) && !(byLabel.exists && byLabel.isHittable) && steps < 12 {
            nudgeUp(app)
            steps += 1
        }
        let link = byID.exists && byID.isHittable ? byID : byLabel
        XCTAssertTrue(link.exists && link.isHittable,
                      "Typography link not reachable. Tree:\n\(app.debugDescription)", file: file, line: line)
        link.tap()
        XCTAssertTrue(element("typographyPreview", in: app).waitForExistence(timeout: 5),
                      "Typography editor did not open", file: file, line: line)
    }

    /// Scrolls the current screen in small steps (about a third of the screen per drag, so a row just below the
    /// edge is not skipped, as a full swipe does on a 40 mm watch) until `element` is hittable. Returns whether
    /// it is.
    @discardableResult
    static func scrollToHittable(_ element: XCUIElement, in app: XCUIApplication, maxSteps: Int = 12) -> Bool {
        var steps = 0
        while !(element.exists && element.isHittable) && steps < maxSteps {
            nudgeUp(app)
            steps += 1
        }
        return element.exists && element.isHittable
    }

    /// Drags the content up by roughly a third of the screen.
    static func nudgeUp(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Drags the content down by roughly a third of the screen (back towards the top of a list).
    static func nudgeDown(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    // MARK: Reading position (`-UITestingReaderPosition`)

    /// Launch argument that makes the reader expose its saved position (`readerPosition`).
    static let readerPositionArgument = "-UITestingReaderPosition"

    /// The reader's position element: value "block=<flat index> offset=<characters> settled=<0|1>".
    static func readerPosition(in app: XCUIApplication) -> XCUIElement {
        element("readerPosition", in: app)
    }

    /// Waits until the reader has settled (no restore, no cover) and, with `expected`, until its position reads
    /// "block=<expected.block> offset=<expected.offset>". Returns the settled value ("block=… offset=… settled=1"),
    /// or nil on a timeout.
    static func settledPosition(in app: XCUIApplication, expected: (block: Int, offset: Int)? = nil,
                                timeout: TimeInterval = 10) -> String? {
        let position = readerPosition(in: app)
        let wanted = expected.map { "block=\($0.block) offset=\($0.offset) settled=1" }
        let predicate = NSPredicate { _, _ in
            guard position.exists, let value = position.value as? String else { return false }
            return wanted.map { value == $0 } ?? value.hasSuffix("settled=1")
        }
        let done = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
        return done == .completed ? position.value as? String : nil
    }

    /// The long seeded book (`-UITestingSeedLongBook`): flat index of the heading of chapter `chapter` (1-based).
    /// Each chapter is a heading and 30 paragraphs (`UITesting.longBookParagraphs` in the app).
    static func longBookHeadingIndex(chapter: Int) -> Int { (chapter - 1) * 31 }

    /// The reader block of the long book's chapter heading `title` ("Chapter 2"), not one of its paragraphs
    /// ("Chapter 2, paragraph 1. …"). Not for "Chapter 1", which would also match "Chapter 10".
    static func headingBlock(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@ AND NOT (label CONTAINS %@)",
                                  "readerBlock", title, ",")).element(boundBy: 0)
    }

    /// The first reader block below the top bar: the one being read. Blocks that end less than 4 pt below the
    /// bar (its frame, or at least the Reading Options button in it) are under it and not counted.
    static func firstVisibleBlock(in app: XCUIApplication) -> XCUIElement? {
        let window = app.windows.firstMatch.frame
        let options = element("readerOptionsButton", in: app)
        let bar = app.navigationBars.firstMatch
        var line = options.exists ? options.frame.maxY : window.minY
        if bar.exists, bar.frame.height > 0, bar.frame.maxY < window.midY { line = max(line, bar.frame.maxY) }
        let blocks = app.descendants(matching: .any).matching(identifier: "readerBlock").allElementsBoundByIndex
        return blocks.filter { $0.exists && $0.frame.maxY > line + 4 && $0.frame.minY < window.maxY }
            .min { $0.frame.minY < $1.frame.minY }
    }

    /// Shows the reader's top bar if it is hidden: a tap on the text toggles it (and opens nothing while hidden).
    /// A bar shown by a tap hides again after 3 s: open Reading Options with `openReaderMenu`, which reveals it
    /// again if needed.
    static func showReaderBar(_ app: XCUIApplication) {
        let options = element("readerOptionsButton", in: app)
        guard !(options.exists && options.isHittable) else { return }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        _ = waitForHittable(options, timeout: 3)
    }

    /// Waits until `element` exists and is hittable. Returns whether it is.
    static func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in element.exists && element.isHittable }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)],
                                timeout: timeout) == .completed
    }

    /// Reading Options -> chapter list -> the chapter titled `title`, which closes the menu. Opens the menu first
    /// (showing the bar if needed). `current` is the chapter the Chapters row should read. Returns whether the
    /// chapter was chosen.
    @discardableResult
    /// `backwardSteps` / `forwardSteps`: how many small drags towards the top / the bottom of the list it may take
    /// to reach the row (a far jump in a book with dozens of chapters needs more than the defaults).
    static func chooseChapter(_ title: String, current: String, in app: XCUIApplication,
                              backwardSteps: Int = 6, forwardSteps: Int = 24,
                              file: StaticString = #filePath, line: UInt = #line) -> Bool {
        openReaderMenu(app, file: file, line: line)
        guard openChapters(app, currentChapter: current, file: file, line: line) else { return false }
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "chapterButton", title)).element(boundBy: 0)
        // The list opens centred on the current chapter: the next one is below it, the previous one above.
        var steps = 0
        while !(row.exists && row.isHittable) && steps < backwardSteps {
            nudgeDown(app)
            steps += 1
        }
        guard scrollToHittable(row, in: app, maxSteps: forwardSteps) else {
            fail("\(title) is not reachable in the chapter list", in: app, file: file, line: line)
            return false
        }
        row.tap()
        guard element("readerOptionsButton", in: app).waitForExistence(timeout: 5) else {
            fail("Choosing \(title) did not close the menu", in: app, file: file, line: line)
            return false
        }
        return true
    }

    /// Closes the sheet on screen (the reader menu) with its close button. Returns whether the reader shows again.
    @discardableResult
    static func closeSheet(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let stepper = element("textSizeStepper", in: app)
        let candidates = ["Close", "Cancel", "Dismiss", "Done"].map { app.buttons[$0] }
        if let button = candidates.first(where: { $0.exists && $0.isHittable }) {
            button.tap()
        } else if let bar = app.navigationBars.allElementsBoundByIndex.last(where: { $0.exists }),
                  let button = bar.buttons.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
            // The frontmost bar is the sheet's (presented content comes last in the tree); its first button closes it.
            button.tap()
        }
        let gone = NSPredicate { _, _ in !stepper.exists }
        guard XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 5) == .completed else {
            fail("The reader menu did not close", in: app, file: file, line: line)
            return false
        }
        return true
    }
}
