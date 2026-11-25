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

    // MARK: Images (#71, `-UITestingSeedIllustratedBook`)

    /// Launch arguments of the illustrated seed (with `seedSampleBook: true`).
    static let illustratedBookArguments = ["-UITestingSeedIllustratedBook"]
    /// The description of the seed's picture, which is its VoiceOver label.
    static let illustrationLabel = "A white rabbit with a pocket watch"

    /// The seed's picture in the text.
    static func illustration(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "readerBlock")
            .matching(NSPredicate(format: "label == %@", illustrationLabel)).element(boundBy: 0)
    }

    /// Scrolls the reader until the middle of `element` is in the middle band of the screen (between a quarter
    /// from the top, below the bar, and a fifth from the bottom), dragging in whichever direction it lies. Unlike
    /// `scrollToHittable`, which only drags forward and so runs past an element that starts out partly hidden
    /// (the illustrated seed is barely two screens long). Returns whether it got there.
    static func scrollIntoMiddle(_ element: XCUIElement, in app: XCUIApplication, maxSteps: Int = 12) -> Bool {
        for _ in 0..<maxSteps {
            let window = app.windows.firstMatch.frame
            guard element.exists else {
                nudgeUp(app)
                continue
            }
            let mid = element.frame.midY
            if mid < window.minY + window.height * 0.25 {
                nudgeDown(app)
            } else if mid > window.maxY - window.height * 0.2 {
                nudgeUp(app)
            } else {
                return true
            }
        }
        return false
    }

    /// Reader (illustrated seed) -> the picture full screen. Returns whether the viewer opened.
    @discardableResult
    static func openImageViewer(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let picture = illustration(in: app)
        guard picture.waitForExistence(timeout: 5), scrollIntoMiddle(picture, in: app) else {
            fail("The picture is not on screen", in: app, file: file, line: line)
            return false
        }
        // A tap on the middle of the picture, whether or not XCUITest counts the whole element as hittable (part of
        // it may be under the bar or past the bottom edge).
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let close = element("imageViewerClose", in: app)
        guard close.waitForExistence(timeout: 5) else {
            fail("The image viewer did not open", in: app, file: file, line: line)
            return false
        }
        return true
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

    // MARK: One snapshot per check

    /// A reader block as one accessibility snapshot saw it.
    struct BlockShot {
        let label: String
        let frame: CGRect
        let value: String
    }

    /// The reader as one accessibility snapshot saw it: its blocks (in tree order), the first window, the first
    /// navigation bar and the first Reading Options button.
    struct ReaderShot {
        let blocks: [BlockShot]
        let window: CGRect
        let bar: CGRect?
        let options: CGRect?

        /// The blocks that are at least partly on screen.
        var onScreen: [BlockShot] {
            blocks.filter { $0.frame.maxY > window.minY && $0.frame.minY < window.maxY && $0.frame.height > 0 }
        }

        /// The first block below the top bar: the one being read. Blocks that end less than 4 pt below the bar (its
        /// frame, or at least the Reading Options button in it) are under it and not counted.
        var firstVisible: BlockShot? {
            var line = options?.maxY ?? window.minY
            if let bar, bar.height > 0, bar.maxY < window.midY { line = max(line, bar.maxY) }
            return blocks.filter { $0.frame.maxY > line + 4 && $0.frame.minY < window.maxY }
                .min { $0.frame.minY < $1.frame.minY }
        }

        /// The first block labelled `label`, if it is in the tree.
        func block(labelled label: String) -> BlockShot? {
            blocks.first { $0.label == label }
        }
    }

    /// One accessibility snapshot of the reader. With the reader's plain stack every block of the loaded chapters is
    /// in the tree, and querying them one `XCUIElement` at a time would make each check a query per block. Nil if the
    /// snapshot fails.
    static func readerShot(in app: XCUIApplication) -> ReaderShot? {
        guard let root = try? app.snapshot() else { return nil }
        var blocks: [BlockShot] = []
        var window: CGRect?
        var bar: CGRect?
        var options: CGRect?
        // Pre-order, so "first" means first in the tree, as `firstMatch` does.
        var stack: [XCUIElementSnapshot] = [root]
        while let node = stack.popLast() {
            if node.identifier == "readerBlock" {
                blocks.append(BlockShot(label: node.label, frame: node.frame, value: (node.value as? String) ?? ""))
            } else if node.identifier == "readerOptionsButton" {
                if options == nil { options = node.frame }
            } else if node.elementType == .navigationBar {
                if bar == nil { bar = node.frame }
            } else if node.elementType == .window {
                if window == nil { window = node.frame }
            }
            stack.append(contentsOf: node.children.reversed())
        }
        return ReaderShot(blocks: blocks, window: window ?? root.frame, bar: bar, options: options)
    }

    /// The first reader block below the top bar (one snapshot; see `ReaderShot.firstVisible`).
    static func firstVisibleBlock(in app: XCUIApplication) -> BlockShot? {
        readerShot(in: app)?.firstVisible
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
        // The list opens centred on the current chapter: the next one is below it, the previous one above. With
        // numbered titles ("Chapter 12.") the visible rows say which way to go, so a drag that flings past the row
        // (a long list scrolls on after the finger lifts) is followed by one back.
        if let wanted = chapterNumber(title) {
            var steps = 0
            while !(row.exists && row.isHittable) && steps < 2 * (backwardSteps + forwardSteps) {
                let shown = app.descendants(matching: .any).matching(identifier: "chapterButton")
                    .allElementsBoundByIndex.compactMap { $0.exists ? chapterNumber($0.label) : nil }
                guard let first = shown.min(), let last = shown.max() else { break }
                let down = wanted < first ? true : wanted > last ? false
                    : row.exists && row.frame.minY < app.windows.firstMatch.frame.midY
                listStep(app, towardsTop: down)
                steps += 1
            }
        }
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

    /// A short drag in a list (a tenth of the screen). A third of the screen flings a long chapter list on by about
    /// four rows after the finger lifts, past the row looked for; a short one moves it by about a row.
    static func listStep(_ app: XCUIApplication, towardsTop: Bool) {
        let window = app.windows.firstMatch
        let a = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let b = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        if towardsTop { a.press(forDuration: 0.05, thenDragTo: b) } else { b.press(forDuration: 0.05, thenDragTo: a) }
    }

    /// The number in a chapter title like "Chapter 12." (nil for other titles).
    static func chapterNumber(_ title: String) -> Int? {
        guard title.hasPrefix("Chapter ") else { return nil }
        let digits = title.dropFirst("Chapter ".count).prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
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
