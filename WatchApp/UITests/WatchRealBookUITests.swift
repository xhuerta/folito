import XCTest

/// Build 49 feedback, on a book shaped like a real novel (`-UITestingSeedVariedBook`: 36 chapters of 8 to 70
/// paragraphs of very different lengths, so the lazy reader's estimated heights are far off): far chapter jumps,
/// forward and backward, and large text-size changes must leave the chapter heading as the first block, its top
/// exactly at the reading line, and the saved position at the heading (character offset 0). The reading line is
/// measured, not assumed: where the book's first heading sits when it opens at its start.
///
/// Runs with the other watch UI tests (`accessibility.yml`, or a targeted run of
/// `FolitoWatchUITests/WatchRealBookUITests`).
final class WatchRealBookUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // Each size test makes three or four trips through Reading Options and the chapter list on a 36-chapter
        // book; the default allowance (3 min) left little room. Within the workflow's 300 s per test.
        executionTimeAllowance = 280
    }

    @MainActor
    private func launchVariedBook() -> (app: XCUIApplication, line: CGFloat)? {
        let app = WatchUI.launch(seedSampleBook: true,
                                 extraArguments: ["-UITestingSeedVariedBook", WatchUI.readerPositionArgument,
                                                  "-UITestingRestoreTrace",
                                                  "-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        WatchUI.openReader(app)
        guard WatchUI.settledPosition(in: app, expected: (0, 0)) != nil else {
            WatchUI.fail("The book did not open at its start", in: app)
            return nil
        }
        let first = heading("Chapter 1.", in: app)
        guard first.waitForExistence(timeout: 5) else {
            WatchUI.fail("The first heading is not on screen", in: app)
            return nil
        }
        // At the start of the book the first block's top is the reading line (`scrollTo(.top)` puts blocks there).
        return (app, first.frame.minY)
    }

    /// The reader block whose text is exactly `title` ("Chapter 12.").
    @MainActor
    private func heading(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "readerBlock", title)).element(boundBy: 0)
    }

    /// For a failure message: where the heading and the first visible block really are on screen, the bar, and the
    /// reader's restore trace (`-UITestingRestoreTrace`: each settle check with the reading line in scroll space, the
    /// target's measured frame, how the restore ended, and the scroll view's geometry).
    @MainActor
    private func diagnostics(_ title: String, in app: XCUIApplication) -> String {
        let block = heading(title, in: app)
        let headingText = block.exists ? "\(block.frame)" : "absent"
        let first = WatchUI.firstVisibleBlock(in: app)
        let firstText = first.map { "\($0.label.prefix(40)) \($0.frame)" } ?? "none"
        let bar = app.navigationBars.firstMatch
        let barText = bar.exists ? "\(bar.frame)" : "none"
        let trace = WatchUI.element("restoreTrace", in: app).value as? String ?? "no trace"
        return "heading on screen: \(headingText); first visible: \(firstText); bar: \(barText); trace: \(trace)"
    }

    /// The reader shows chapter `title`'s heading as the first block below the bar, its top at `line`, the position
    /// is that heading with offset 0, and nothing moves or is re-saved for 2 s. Returns the settled position.
    @MainActor
    @discardableResult
    private func assertHeadingAtTheTop(_ title: String, readingLine line: CGFloat, in app: XCUIApplication,
                                       step: String, file: StaticString = #filePath,
                                       line sourceLine: UInt = #line) -> String? {
        guard let settled = WatchUI.settledPosition(in: app) else {
            WatchUI.fail("\(step): the reader did not settle. " + diagnostics(title, in: app), in: app,
                         file: file, line: sourceLine)
            return nil
        }
        XCTAssertTrue(settled.contains(" offset=0 "),
                      "\(step): the position is \(settled), not a block's start. " + diagnostics(title, in: app),
                      file: file, line: sourceLine)
        let block = heading(title, in: app)
        guard block.waitForExistence(timeout: 5) else {
            WatchUI.fail("\(step): the heading \(title) is not on screen (position \(settled)). "
                         + diagnostics(title, in: app), in: app, file: file, line: sourceLine)
            return nil
        }
        let top = block.frame.minY
        let firstLabel = WatchUI.firstVisibleBlock(in: app)?.label
        if abs(top - line) > 1 || firstLabel != title {
            XCTFail("\(step): the heading's top is at \(top), the reading line at \(line), first visible block "
                    + "\(firstLabel?.prefix(40) ?? "none"). " + diagnostics(title, in: app),
                    file: file, line: sourceLine)
        }
        sleep(2)
        XCTAssertEqual(block.frame.minY, top, accuracy: 1,
                       "\(step): the text moved after it was revealed. " + diagnostics(title, in: app),
                       file: file, line: sourceLine)
        XCTAssertEqual(WatchUI.readerPosition(in: app).value as? String, settled,
                       "\(step): the position changed after landing. " + diagnostics(title, in: app), file: file, line: sourceLine)
        return settled
    }

    /// Far forward (1 → 30) and far backward (30 → 3) through the chapter list.
    @MainActor
    func testFarChapterJumpsLandAtTheHeading() {
        guard let launched = launchVariedBook() else { return }
        let app = launched.app, line = launched.line
        guard WatchUI.chooseChapter("Chapter 30.", current: "Chapter 1.", in: app, backwardSteps: 0, forwardSteps: 40)
        else { return }
        assertHeadingAtTheTop("Chapter 30.", readingLine: line, in: app, step: "far forward jump")
        logWindowCost(in: app, step: "far forward jump (Chapter 30.: 66 paragraphs, the seed's longest text)")

        guard WatchUI.chooseChapter("Chapter 3.", current: "Chapter 30.", in: app, backwardSteps: 40, forwardSteps: 6)
        else { return }
        assertHeadingAtTheTop("Chapter 3.", readingLine: line, in: app, step: "far backward jump")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "watch-real-book-backward-jump"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// At a chapter heading: text size 16 → 15, then 15 → 12 and 12 → 16 each in one visit to Reading Options.
    @MainActor
    func testLargeTextSizeChangesKeepTheHeadingAtTheTop() {
        guard let launched = launchVariedBook() else { return }
        let app = launched.app, line = launched.line
        guard WatchUI.chooseChapter("Chapter 12.", current: "Chapter 1.", in: app, backwardSteps: 0, forwardSteps: 30)
        else { return }
        guard let position = assertHeadingAtTheTop("Chapter 12.", readingLine: line, in: app, step: "jump to Chapter 12.")
        else { return }

        for (from, to) in [(16, 15), (15, 12), (12, 16)] {
            let step = "text size \(from) → \(to)"
            guard changeTextSize(by: to - from, in: app, step: step) else { return }
            let settled = assertHeadingAtTheTop("Chapter 12.", readingLine: line, in: app, step: step)
            XCTAssertEqual(settled, position,
                           "\(step): the reading position changed. " + diagnostics("Chapter 12.", in: app))
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "watch-real-book-text-size"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Mid-chapter: after reading a little into "Chapter 12.", text size 16 → 15 → 12 → 16 keeps the same block and
    /// character offset, and the same block first below the bar.
    @MainActor
    func testLargeTextSizeChangesKeepTheLineMidChapter() {
        guard let launched = launchVariedBook() else { return }
        let app = launched.app, line = launched.line
        guard WatchUI.chooseChapter("Chapter 12.", current: "Chapter 1.", in: app, backwardSteps: 0, forwardSteps: 30)
        else { return }
        assertHeadingAtTheTop("Chapter 12.", readingLine: line, in: app, step: "jump to Chapter 12.")
        for _ in 0..<3 { WatchUI.nudgeUp(app) }
        sleep(1)
        WatchUI.showReaderBar(app)
        let firstBefore = WatchUI.firstVisibleBlock(in: app)?.label
        guard let position = WatchUI.settledPosition(in: app) else {
            return WatchUI.fail("The reader did not settle after reading on. " + diagnostics("Chapter 12.", in: app), in: app)
        }
        for (from, to) in [(16, 15), (15, 12), (12, 16)] {
            let step = "mid-chapter text size \(from) → \(to)"
            guard changeTextSize(by: to - from, in: app, step: step) else { return }
            guard let settled = WatchUI.settledPosition(in: app) else {
                return WatchUI.fail("\(step): the reader did not settle. " + diagnostics("Chapter 12.", in: app), in: app)
            }
            XCTAssertEqual(settled, position, "\(step): the reading position changed. " + diagnostics("Chapter 12.", in: app))
            XCTAssertEqual(WatchUI.firstVisibleBlock(in: app)?.label, firstBefore,
                           "\(step): another block is first below the bar. " + diagnostics("Chapter 12.", in: app))
        }
    }

    /// Reading forward from "Chapter 3." (its own chapter loaded) into "Chapter 4." (appended below while reading):
    /// the position only moves forward, a few blocks per drag at most, and the next heading stays put once on screen.
    @MainActor
    func testReadingForwardAcrossAChapterEndDoesNotJump() {
        guard let launched = launchVariedBook() else { return }
        let app = launched.app, line = launched.line
        guard WatchUI.chooseChapter("Chapter 3.", current: "Chapter 1.", in: app, backwardSteps: 0, forwardSteps: 12)
        else { return }
        assertHeadingAtTheTop("Chapter 3.", readingLine: line, in: app, step: "jump to Chapter 3.")
        // Flat index of "Chapter 4." in the varied book (UITesting.variedBook: chapter 3 is a heading and 13 paragraphs).
        let nextHeading = 60
        var previous = 46
        let next = heading("Chapter 4.", in: app)
        for step in 0..<80 {
            WatchUI.nudgeUp(app)
            sleep(1)
            guard let value = WatchUI.settledPosition(in: app, timeout: 5), let block = blockIndex(value) else {
                return WatchUI.fail("Reading forward, drag \(step): no settled position. " + diagnostics("Chapter 4.", in: app),
                                    in: app)
            }
            XCTAssertGreaterThanOrEqual(block, previous, "Reading forward, drag \(step): the position went back "
                                        + "from \(previous) to \(block). " + diagnostics("Chapter 4.", in: app))
            XCTAssertLessThanOrEqual(block - previous, 8, "Reading forward, drag \(step): the text jumped from block "
                                     + "\(previous) to \(block). " + diagnostics("Chapter 4.", in: app))
            previous = block
            if block >= nextHeading, next.exists { break }
        }
        guard previous >= nextHeading else {
            return WatchUI.fail("Reading forward never reached Chapter 4. (block \(previous)). "
                                + diagnostics("Chapter 4.", in: app), in: app)
        }
        if next.exists {
            let top = next.frame.minY
            sleep(2)
            XCTAssertEqual(next.frame.minY, top, accuracy: 1,
                           "The next chapter moved while nobody scrolled. " + diagnostics("Chapter 4.", in: app))
        }
    }

    /// Reading up from the start of "Chapter 4." through Chapters 3 and 2 into Chapter 1 (three chapter starts): the
    /// text scrolls on continuously, the position only moves back, a few blocks per drag at most, and each prepend of
    /// a previous chapter (the trace's "prepend kept block N: moved=X") leaves the block at the reading line within
    /// 1 pt. Also: the bar hides when scrolling down from a chapter's start, now that the previous chapter is above it.
    @MainActor
    func testReadingUpAcrossChapterStartsIsContinuous() {
        guard let launched = launchVariedBook() else { return }
        let app = launched.app, line = launched.line
        guard WatchUI.chooseChapter("Chapter 4.", current: "Chapter 1.", in: app, backwardSteps: 0, forwardSteps: 12)
        else { return }
        assertHeadingAtTheTop("Chapter 4.", readingLine: line, in: app, step: "jump to Chapter 4.")

        let options = WatchUI.element("readerOptionsButton", in: app)
        for _ in 0..<3 { WatchUI.nudgeUp(app) }
        let hidden = NSPredicate { _, _ in !(options.exists && options.isHittable) }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 5),
                       .completed, "The bar should hide when scrolling down from a chapter's start")
        sleep(1)
        guard let start = WatchUI.settledPosition(in: app).flatMap({ blockIndex($0) }) else {
            return WatchUI.fail("No settled position in Chapter 4. " + diagnostics("Chapter 4.", in: app), in: app)
        }

        // Flat indices in the varied book: Chapter 2. starts at 35, Chapter 3. at 46, Chapter 4. at 60.
        let chapterOneEnd = 35
        var previous = start
        var prepends = Set<String>()
        for step in 0..<150 {
            WatchUI.nudgeDown(app)
            sleep(1)
            guard let value = WatchUI.settledPosition(in: app, timeout: 5), let block = blockIndex(value) else {
                return WatchUI.fail("Reading up, drag \(step): no settled position. " + diagnostics("Chapter 3.", in: app),
                                    in: app)
            }
            XCTAssertLessThanOrEqual(block, previous, "Reading up, drag \(step): the position went forward from "
                                     + "\(previous) to \(block). " + diagnostics("Chapter 3.", in: app))
            XCTAssertLessThanOrEqual(previous - block, 8, "Reading up, drag \(step): the text jumped from block "
                                     + "\(previous) to \(block). " + diagnostics("Chapter 3.", in: app))
            previous = block
            let trace = WatchUI.element("restoreTrace", in: app).value as? String ?? ""
            for entry in trace.components(separatedBy: " | ") where entry.hasPrefix("prepend kept block") {
                prepends.insert(entry)
            }
            if block < chapterOneEnd { break }
        }
        guard previous < chapterOneEnd else {
            return WatchUI.fail("Reading up never reached Chapter 1. (block \(previous)). "
                                + diagnostics("Chapter 2.", in: app), in: app)
        }
        XCTAssertFalse(prepends.isEmpty, "Reading up from Chapter 4. prepends Chapters 2. and 1. "
                       + diagnostics("Chapter 2.", in: app))
        for entry in prepends {
            let moved = entry.components(separatedBy: "moved=").last.flatMap { Double($0) } ?? .infinity
            XCTAssertLessThanOrEqual(abs(moved), 1, "A prepend moved the text: \(entry). " + diagnostics("Chapter 2.", in: app))
        }
        print("[prepends] \(prepends.sorted().joined(separator: "; "))")
    }

    /// Build 51 feedback: fast flings up from the start of "Chapter 4." into Chapter 1. (three chapter starts). The
    /// position never moves forward between flings (no pull-back after a prepend), never sticks at the edge of the
    /// loaded chapters (no bounce), and every prepend measured while nobody scrolled kept the block at the reading
    /// line within 1 pt.
    @MainActor
    func testFastFlingsUpAcrossChapterStartsNeverBounceOrPullBack() {
        guard let launched = launchVariedBook() else { return }
        let app = launched.app, line = launched.line
        guard WatchUI.chooseChapter("Chapter 4.", current: "Chapter 1.", in: app, backwardSteps: 0, forwardSteps: 12)
        else { return }
        assertHeadingAtTheTop("Chapter 4.", readingLine: line, in: app, step: "jump to Chapter 4.")

        // Flat indices in the varied book: Chapter 2. starts at 35, Chapter 3. at 46, Chapter 4. at 60.
        let chapterTwoStart = 35
        var previous = 60
        var unchanged = 0
        var prepends = Set<String>()
        let window = app.windows.firstMatch
        for fling in 0..<25 {
            window.swipeDown()
            sleep(2)
            guard let value = WatchUI.settledPosition(in: app, timeout: 5), let block = blockIndex(value) else {
                return WatchUI.fail("Fling \(fling): no settled position. " + diagnostics("Chapter 3.", in: app), in: app)
            }
            XCTAssertLessThanOrEqual(block, previous, "Fling \(fling): the text was pulled forward from block "
                                     + "\(previous) to \(block). " + diagnostics("Chapter 3.", in: app))
            unchanged = block == previous ? unchanged + 1 : 0
            XCTAssertLessThan(unchanged, 3, "Fling \(fling): stuck at block \(block) for three flings. "
                              + diagnostics("Chapter 3.", in: app))
            previous = block
            let trace = WatchUI.element("restoreTrace", in: app).value as? String ?? ""
            for entry in trace.components(separatedBy: " | ") where entry.hasPrefix("prepend kept block") {
                prepends.insert(entry)
            }
            if block < chapterTwoStart { break }
        }
        guard previous < chapterTwoStart else {
            return WatchUI.fail("Flinging up never reached Chapter 1. (block \(previous)). "
                                + diagnostics("Chapter 2.", in: app), in: app)
        }
        XCTAssertGreaterThanOrEqual(prepends.count, 2, "Chapters 3., 2. and 1. are prepended on the way up: "
                                    + "\(prepends.sorted())")
        for entry in prepends where !entry.hasSuffix("while scrolling") {
            let moved = entry.components(separatedBy: "moved=").last.flatMap { Double($0) } ?? .infinity
            XCTAssertLessThanOrEqual(abs(moved), 1, "A prepend moved the text: \(entry). " + diagnostics("Chapter 2.", in: app))
        }
        print("[fling-prepends] \(prepends.sorted().joined(separator: "; "))")
    }

    /// Prints the trace's "window shown" entries (how long a loaded chapter took to show its target) to the test log.
    @MainActor
    private func logWindowCost(in app: XCUIApplication, step: String) {
        let trace = WatchUI.element("restoreTrace", in: app).value as? String ?? ""
        let shown = trace.components(separatedBy: " | ").filter { $0.hasPrefix("window shown") }
        print("[window-cost] \(step): \(shown.isEmpty ? "no entry" : shown.joined(separator: "; "))")
    }

    /// The block index in a reader position value ("block=46 offset=0 settled=1").
    private func blockIndex(_ value: String) -> Int? {
        guard let part = value.split(separator: " ").first(where: { $0.hasPrefix("block=") }) else { return nil }
        return Int(part.dropFirst("block=".count))
    }

    /// Opens Reading Options, taps − or + `abs(delta)` times (its first row is the text size stepper) and closes it.
    @MainActor
    private func changeTextSize(by delta: Int, in app: XCUIApplication, step: String) -> Bool {
        WatchUI.openReaderMenu(app)
        let stepper = WatchUI.element("textSizeStepper", in: app)
        for _ in 0..<abs(delta) {
            let before = stepper.value as? String
            // The − and + buttons at the stepper's two ends (hidden from accessibility: one adjustable element).
            stepper.coordinate(withNormalizedOffset: CGVector(dx: delta < 0 ? 0.08 : 0.92, dy: 0.5)).tap()
            let changed = NSPredicate { _, _ in (stepper.value as? String) != before }
            guard XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: changed, object: nil)],
                                   timeout: 5) == .completed else {
                WatchUI.fail("\(step): the text size did not change from \(before ?? "?")", in: app)
                return false
            }
        }
        return WatchUI.closeSheet(app)
    }
}
