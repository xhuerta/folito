import XCTest

/// Deterministic scrolling to, and tapping of, rows that can be taller than half the screen (a catalog row at
/// AX5 is up to about 380 pt). Shared by `CatalogsUITests` and `AccessibilityAuditTests`.
///
/// Why not "swipe until hittable": two CI failures on PR #190, read from their screen recordings.
/// - Run 45522603339 (`testCatalogSignInAudit`, AX5): the audit's press-and-drag started on a catalog row in the
///   middle of the screen, and the slow drag became a tap: it opened Project Gutenberg, the next one opened its
///   *Latest* section, and the target row was never reached.
/// - Job 138876470109 (`testCatalogsAtLargestTextSize`): one `swipeDown()` flung the list so far that the
///   Project Gutenberg row ended with its centre under the navigation bar; it still counted as hittable, the
///   tap did nothing, and its *Popular* section never appeared.
///
/// So drags start in the left margin of the screen, where no row is, move by a computed distance and hold before
/// lifting (no fling), and the loop stops only when the row's tap point (its centre) is between the bars and
/// above the keyboard, read after the content has stopped moving.
enum RowNavigation {
    /// Distance kept from the bars and the keyboard, as in the audits' clear area.
    private static let margin: CGFloat = 16
    /// Where drags start: inside the 16 pt content margin of the screens' cards and grouped lists.
    private static let dragX: CGFloat = 8
    /// A scroll view starts moving only after the finger has moved about this far.
    private static let slop: CGFloat = 12

    /// The part of the screen where a tap reaches the content: below the navigation bar, above the tab bar and
    /// the keyboard.
    @MainActor
    static func clearRange(in app: XCUIApplication) -> ClosedRange<CGFloat> {
        let window = app.windows.firstMatch.frame
        let navigationBar = app.navigationBars.firstMatch
        let tabBar = app.tabBars.firstMatch
        let keyboard = app.keyboards.firstMatch
        let top = (navigationBar.exists ? navigationBar.frame.maxY : window.minY) + margin
        var bottom = (tabBar.exists ? tabBar.frame.minY : window.maxY) - margin
        if keyboard.exists, !keyboard.frame.isEmpty { bottom = min(bottom, keyboard.frame.minY - margin) }
        return top...max(top, bottom)
    }

    /// Scrolls until the centre of `element` is in `clearRange`, or the content stops moving.
    ///
    /// Kept cheap on purpose: every query and snapshot is a round trip to the app (0.1 to 0.3 s on CI), and a
    /// walk through the catalogs at AX5 makes some 25 drags. With a fresh clear area, bar check and before/after
    /// snapshots per drag, `testCatalogsAtLargestTextSize` took 206 s, over the 180 s per-test allowance of CI
    /// (`-default-test-execution-time-allowance 180`). XCTest then let the test finish but killed and restarted
    /// the test runner while launching the next test, and xcodebuild exited 65 although every test passed
    /// (PR #190, jobs 138920508962 and 138956279104). So the clear area and the bars are read once per call
    /// (scrolling does not move them), a drag reuses the snapshot that ended the previous wait, and a drag covers
    /// most of the clear area.
    @MainActor
    static func reveal(_ element: XCUIElement, in app: XCUIApplication, maxDrags: Int = 15) {
        let range = clearRange(in: app)
        let bars = barFrames(in: app)
        // When the element is not loaded yet, a drag moves most of the clear area, so that what was just below
        // it comes into it and nothing is skipped.
        let step = max(40, (range.upperBound - range.lowerBound) * 0.8)
        var current = waitForSettle(app)
        for _ in 0..<maxDrags {
            let distance: CGFloat
            if element.exists, !element.frame.isEmpty {
                let frame = element.frame
                let centre = CGPoint(x: frame.midX, y: frame.midY)
                if range.contains(centre.y) || bars.contains(where: { $0.contains(centre) }) { return }
                // Positive: the row is below the clear area, so the content moves up.
                distance = centre.y - (range.lowerBound + range.upperBound) / 2
            } else {
                distance = step // not loaded yet: further down
            }
            guard let moved = drag(app, by: max(-step, min(step, distance)), in: range, from: current) else { return }
            current = moved
        }
    }

    /// The navigation bar and the (visible) tab bar: a button there (such as *Save* in Edit Catalog) is not
    /// scrolled.
    @MainActor
    private static func barFrames(in app: XCUIApplication) -> [CGRect] {
        var frames: [CGRect] = []
        let navigationBar = app.navigationBars.firstMatch
        if navigationBar.exists { frames.append(navigationBar.frame) }
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists, tabBar.isHittable { frames.append(tabBar.frame) }
        return frames
    }

    /// Scrolls `element` into reach (see `reveal`), taps it and waits for `destination`. If the destination did
    /// not appear and the element is still there to tap (the tap did not navigate), it is revealed and tapped
    /// once more. Returns whether the destination appeared.
    @MainActor
    @discardableResult
    static func open(_ element: XCUIElement, in app: XCUIApplication, expecting destination: XCUIElement,
                     timeout: TimeInterval = 10) -> Bool {
        reveal(element, in: app)
        guard element.exists, element.isHittable else { return false }
        element.tap()
        if destination.waitForExistence(timeout: timeout) { return true }
        guard element.exists, element.isHittable else { return false }
        reveal(element, in: app)
        element.tap()
        return destination.waitForExistence(timeout: timeout)
    }

    /// Drags the content up by about `distance` points (down when negative) within `range`, from the left
    /// margin, holding at the end so that it does not keep moving. `before` is the signature of the screen before
    /// the drag; returns the one after it, or nil when the content did not move.
    @MainActor
    private static func drag(_ app: XCUIApplication, by distance: CGFloat, in range: ClosedRange<CGFloat>,
                             from before: [String]) -> [String]? {
        guard abs(distance) >= 1 else { return nil }
        let centre = (range.lowerBound + range.upperBound) / 2
        let half = min((abs(distance) + slop) / 2, (range.upperBound - range.lowerBound) / 2)
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        let startY = distance > 0 ? centre + half : centre - half
        let endY = distance > 0 ? centre - half : centre + half
        let start = origin.withOffset(CGVector(dx: dragX, dy: startY))
        let end = origin.withOffset(CGVector(dx: dragX, dy: endY))
        // The hold at the end stops the finger before it lifts, so the list does not fling whatever the speed.
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: XCUIGestureVelocity(800),
                    thenHoldForDuration: 0.3)
        let after = waitForSettle(app)
        return after == before ? nil : after
    }

    /// Waits until the texts on screen stop moving, and returns their signature then.
    @MainActor
    @discardableResult
    static func waitForSettle(_ app: XCUIApplication) -> [String] {
        var previous = signature(app)
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.15)
            let current = signature(app)
            if current == previous { return current }
            previous = current
        }
        return previous
    }

    /// Labels and positions of the texts on screen, from one snapshot.
    @MainActor
    private static func signature(_ app: XCUIApplication) -> [String] {
        autoreleasepool { () -> [String] in
            guard let snapshot = try? app.snapshot() else { return [] }
            let screen = snapshot.frame
            var texts: [String] = []
            var stack = [snapshot]
            while let node = stack.popLast() {
                if node.elementType == .staticText, node.frame.intersects(screen) {
                    texts.append("\(node.label)@\(Int(node.frame.minY))")
                }
                stack.append(contentsOf: node.children)
            }
            return texts
        }
    }
}
