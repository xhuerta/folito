import XCTest

/// Auto-scroll (#67): started from Reading Options, the text moves by itself; a tap pauses it (the text stays
/// put and the paused badge shows), and Reading Options stops it. Runs with the other watch UI tests
/// (`accessibility.yml`, or a targeted run of `FolitoWatchUITests/WatchAutoScrollUITests`).
///
/// The book is the App Store seed's *Pride and Prejudice* opening (`-UITestingSeedAppStore`), long enough to
/// scroll for several seconds; the one-paragraph sample book is not.
final class WatchAutoScrollUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The first text block that starts below the top bar, with its label and top edge.
    @MainActor
    private func firstVisibleBlock(_ app: XCUIApplication) -> (label: String, minY: CGFloat)? {
        let screen = app.windows.firstMatch.frame
        let blocks = app.descendants(matching: .any).matching(identifier: "readerBlock").allElementsBoundByIndex
        guard let block = blocks.first(where: { $0.frame.maxY > screen.minY + screen.height * 0.3 && $0.frame.minY < screen.maxY })
        else { return nil }
        return (block.label, block.frame.minY)
    }

    /// Top edge of the block labelled `label` now, or nil when it is no longer in the tree (scrolled away).
    @MainActor
    private func minY(ofBlock label: String, in app: XCUIApplication) -> CGFloat? {
        let block = app.descendants(matching: .any).matching(identifier: "readerBlock")
            .matching(NSPredicate(format: "label == %@", label)).element(boundBy: 0)
        return block.exists ? block.frame.minY : nil
    }

    @MainActor
    private func tapAutoScrollButton(_ app: XCUIApplication, expecting label: String) {
        WatchUI.openReaderMenu(app)
        let button = WatchUI.element("autoScrollButton", in: app)
        guard WatchUI.scrollToHittable(button, in: app) else {
            return WatchUI.fail("Reading Options did not offer \(label)", in: app)
        }
        XCTAssertEqual(button.label, label)
        button.tap()
        XCTAssertTrue(WatchUI.element("readerBlock", in: app).waitForExistence(timeout: 5),
                      "The menu should close and show the book")
    }

    @MainActor
    func testStartPauseAndStop() {
        let app = XCUIApplication()
        // Auto-scroll is behind a feature flag (off in the app): the tests turn it on.
        app.launchArguments += ["-UITestingSeedAppStore", "-UITestingEnableAutoScroll",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(WatchUI.libraryRow(in: app).waitForExistence(timeout: 45), "Library screen did not appear")
        WatchUI.openReader(app)
        sleep(1)
        XCTAssertFalse(WatchUI.element("autoScrollControl", in: app).exists, "Auto-scroll never starts by itself")

        tapAutoScrollButton(app, expecting: "Start Auto-Scroll")
        let control = WatchUI.element("autoScrollControl", in: app)
        guard control.waitForExistence(timeout: 5) else {
            return WatchUI.fail("Auto-scroll did not start", in: app)
        }
        XCTAssertEqual(control.label, "Auto-Scroll")
        XCTAssertTrue(control.value as? String == "Speed 3 of 7", "VoiceOver value: \(String(describing: control.value))")

        // The text moves by itself (about 8 pt a second at the default speed and text size).
        sleep(2)
        guard let before = firstVisibleBlock(app) else { return WatchUI.fail("No text block on screen", in: app) }
        // Reading mode: the top bar hides while it runs.
        let options = WatchUI.element("readerOptionsButton", in: app)
        XCTAssertFalse(options.exists && options.isHittable, "Running: the top bar should hide")
        sleep(5)
        if let after = minY(ofBlock: before.label, in: app) {
            XCTAssertLessThan(after, before.minY - 10, "The text should have scrolled up by itself")
        }
        // A tap pauses: the paused badge shows and the text stays put.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        guard WatchUI.element("autoScrollPaused", in: app).waitForExistence(timeout: 5) else {
            return WatchUI.fail("A tap should pause auto-scroll", in: app)
        }
        XCTAssertFalse(control.exists, "Paused: nothing covers the text")
        sleep(1)
        guard let paused = firstVisibleBlock(app) else { return WatchUI.fail("No text block on screen", in: app) }
        sleep(3)
        if let still = minY(ofBlock: paused.label, in: app) {
            XCTAssertEqual(still, paused.minY, accuracy: 1, "Paused: the text must not move")
        } else {
            XCTFail("Paused: the text must not move (the block scrolled away)")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "watch-autoscroll-paused"
        shot.lifetime = .keepAlways
        add(shot)

        // The top bar hides while auto-scroll runs and comes back when it pauses, so Reading Options stops it.
        XCTAssertTrue(WatchUI.element("readerOptionsButton", in: app).isHittable, "Paused: the top bar should be back")
        tapAutoScrollButton(app, expecting: "Stop Auto-Scroll")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                             object: WatchUI.element("autoScrollPaused", in: app))
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "Stopping should remove the paused badge")
        XCTAssertFalse(WatchUI.element("autoScrollControl", in: app).exists, "Stopped: nothing covers the text")
    }
    /// A text block on screen: its frame as XCUITest reports it, whether all of it is inside the screen, and its
    /// whole laid-out height as the app reports it (`-UITestingBlockHeights`: the accessibility value "h=…").
    private struct BlockSnapshot {
        let frame: CGRect
        let fullyOnScreen: Bool
        let height: CGFloat?
    }

    /// The on-screen text blocks, by label.
    ///
    /// The frame alone cannot be compared: the seed's paragraphs are mostly taller than the 197 pt screen, and
    /// XCUITest reports a scroll view's block with its whole frame past the screen's edge, but a block drawn by
    /// auto-scroll cut at it (CI: a 267.5 pt paragraph read 130.5 pt while running). So the app reports each
    /// block's laid-out height itself, the same way for the reader and for auto-scroll.
    @MainActor
    private func visibleBlocks(_ app: XCUIApplication) -> [String: BlockSnapshot] {
        let screen = app.windows.firstMatch.frame
        var result: [String: BlockSnapshot] = [:]
        for block in app.descendants(matching: .any).matching(identifier: "readerBlock").allElementsBoundByIndex {
            let frame = block.frame
            guard frame.maxY > screen.minY, frame.minY < screen.maxY, !block.label.isEmpty else { continue }
            let whole = frame.minY >= screen.minY - 0.5 && frame.maxY <= screen.maxY + 0.5
            let value = (block.value as? String) ?? ""
            let height = value.hasPrefix("h=") ? Double(value.dropFirst(2)).map { CGFloat($0) } : nil
            result[block.label] = BlockSnapshot(frame: frame, fullyOnScreen: whole, height: height)
        }
        return result
    }

    /// The frames and heights, for the test log (evidence when a comparison fails).
    @MainActor
    private func attachFrames(_ name: String, _ blocks: [String: BlockSnapshot], _ app: XCUIApplication) {
        let screen = app.windows.firstMatch.frame
        let lines = blocks.sorted { $0.value.frame.minY < $1.value.frame.minY }.map { label, block in
            "\(block.fullyOnScreen ? "whole" : "cut  ") h=\(block.height.map { "\($0)" } ?? "?") \(block.frame)  "
                + "\(label.prefix(40))"
        }
        let text = XCTAttachment(string: "screen \(screen)\n" + lines.joined(separator: "\n"))
        text.name = name
        text.lifetime = .keepAlways
        add(text)
    }

    /// Every block on screen in both: its whole laid-out height must not change (a block squeezed or cut with
    /// "…" by the auto-scroll layout is shorter). A block wholly on screen must also be drawn at that height, so
    /// the reported value is the one on screen. Returns how many blocks were compared.
    @MainActor
    private func compareHeights(_ before: [String: BlockSnapshot], _ now: [String: BlockSnapshot],
                                when: String) -> Int {
        var compared = 0
        for (label, was) in before {
            guard let block = now[label] else { continue }
            guard let wasHeight = was.height, let height = block.height else {
                XCTFail("\(when): no height reported for \(label.prefix(40)) (-UITestingBlockHeights)")
                continue
            }
            compared += 1
            XCTAssertEqual(height, wasHeight, accuracy: 1,
                           "\(when): a block must keep its full height (squeezed or cut short with \u{2026}?): "
                           + "before \(wasHeight), now \(height): \(label.prefix(40))")
            if block.fullyOnScreen {
                XCTAssertEqual(block.frame.height, height, accuracy: 1,
                               "\(when): drawn at another height than reported: \(block.frame): \(label.prefix(40))")
            }
        }
        return compared
    }

    @MainActor
    private func attachScreenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The running text must look exactly like the reader's (build 47: a box, a jump at the start, every block
    /// cut to a line ending in "…"). The same blocks keep the same height once auto-scroll draws them (a cut
    /// block is shorter; its accessibility label is the full text either way, so "…" cannot be read from the
    /// tree), and the text does not jump when it starts. Screenshots "autoscroll-before" (bar hidden, just
    /// before), "autoscroll-running" (just after the start) and "autoscroll-running-later" (about 3 s on) are
    /// kept for a visual comparison.
    @MainActor
    func testRunningTextLooksLikeTheReader() {
        let app = XCUIApplication()
        // Auto-scroll is behind a feature flag (off in the app): the tests turn it on.
        app.launchArguments += ["-UITestingSeedAppStore", "-UITestingEnableAutoScroll", "-UITestingBlockHeights",
                                "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(WatchUI.libraryRow(in: app).waitForExistence(timeout: 45), "Library screen did not appear")
        WatchUI.openReader(app)
        sleep(1)
        // Reading mode: scrolled just enough for the bar to hide, as when auto-scroll runs. Not further: the
        // seed text is only a few screens long, and three nudges reached its end, where auto-scroll rightly
        // stops at once (the first CI run of this test failed that way: "Auto-scroll did not start").
        let options = WatchUI.element("readerOptionsButton", in: app)
        var nudges = 0
        repeat {
            WatchUI.nudgeUp(app)
            nudges += 1
            sleep(1)
        } while nudges < 3 && options.exists && options.isHittable
        sleep(1)
        let before = visibleBlocks(app)
        XCTAssertFalse(before.isEmpty, "No text block on screen")
        attachScreenshot("autoscroll-before", app)
        attachFrames("autoscroll-before-frames", before, app)

        // A tap shows the bar (it does not open the word picker while the bar is hidden), then Start.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        tapAutoScrollButton(app, expecting: "Start Auto-Scroll")
        guard WatchUI.element("autoScrollControl", in: app).waitForExistence(timeout: 5) else {
            return WatchUI.fail("Auto-scroll did not start", in: app)
        }
        usleep(300_000)
        attachScreenshot("autoscroll-running", app)
        let running = visibleBlocks(app)
        attachFrames("autoscroll-running-frames", running, app)
        let shared = Set(before.keys).intersection(running.keys)
        XCTAssertFalse(shared.isEmpty, "The text on screen should be the same blocks right after the start")
        // No jump: every block still on screen starts where it did (the top edge is never cut short at the
        // bottom of the screen, so this also holds for blocks running past it).
        for label in shared where before[label]!.frame.minY >= app.windows.firstMatch.frame.minY {
            XCTAssertEqual(running[label]!.frame.minY, before[label]!.frame.minY, accuracy: 30,
                           "The text must not jump when auto-scroll starts: before \(before[label]!.frame), "
                           + "now \(running[label]!.frame): \(label.prefix(40))")
        }
        // A single paragraph can fill the screen, so one shared block is enough (its whole height is compared).
        XCTAssertGreaterThanOrEqual(compareHeights(before, running, when: "Just after the start"), 1,
                                    "No block on screen both before and after the start to compare")

        sleep(3)
        attachScreenshot("autoscroll-running-later", app)
        let later = visibleBlocks(app)
        attachFrames("autoscroll-running-later-frames", later, app)
        XCTAssertGreaterThanOrEqual(compareHeights(before, later, when: "A few seconds on"), 1,
                                    "At least one block still on screen a few seconds on")
    }
}
