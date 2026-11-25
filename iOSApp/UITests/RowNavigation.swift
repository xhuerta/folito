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
    @MainActor
    static func reveal(_ element: XCUIElement, in app: XCUIApplication, maxDrags: Int = 15) {
        waitForSettle(app)
        let step = app.windows.firstMatch.frame.height * 0.4
        for _ in 0..<maxDrags {
            let range = clearRange(in: app)
            let distance: CGFloat
            if element.exists, !element.frame.isEmpty {
                let frame = element.frame
                if range.contains(frame.midY) || inBar(frame, in: app) { return }
                // Positive: the row is below the clear area, so the content moves up.
                distance = frame.midY - (range.lowerBound + range.upperBound) / 2
            } else {
                distance = step // not loaded yet: further down
            }
            guard drag(app, by: max(-step, min(step, distance))) else { return }
        }
    }

    /// A button of the navigation bar or the tab bar (such as *Save* in Edit Catalog) is not scrolled.
    @MainActor
    private static func inBar(_ frame: CGRect, in app: XCUIApplication) -> Bool {
        let navigationBar = app.navigationBars.firstMatch
        let tabBar = app.tabBars.firstMatch
        return (navigationBar.exists && navigationBar.frame.contains(CGPoint(x: frame.midX, y: frame.midY)))
            || (tabBar.exists && tabBar.isHittable && tabBar.frame.contains(CGPoint(x: frame.midX, y: frame.midY)))
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

    /// Drags the content up by about `distance` points (down when negative), from the left margin, holding at the
    /// end so that it does not keep moving. Returns whether the content moved.
    @MainActor
    @discardableResult
    static func drag(_ app: XCUIApplication, by distance: CGFloat) -> Bool {
        guard abs(distance) >= 1 else { return false }
        let range = clearRange(in: app)
        let centre = (range.lowerBound + range.upperBound) / 2
        let half = min((abs(distance) + slop) / 2, (range.upperBound - range.lowerBound) / 2)
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        let startY = distance > 0 ? centre + half : centre - half
        let endY = distance > 0 ? centre - half : centre + half
        let start = origin.withOffset(CGVector(dx: dragX, dy: startY))
        let end = origin.withOffset(CGVector(dx: dragX, dy: endY))
        let before = signature(app)
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForSettle(app)
        return signature(app) != before
    }

    /// Waits until the texts on screen stop moving.
    @MainActor
    static func waitForSettle(_ app: XCUIApplication) {
        var previous = signature(app)
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.25)
            let current = signature(app)
            if current == previous { return }
            previous = current
        }
    }

    /// Labels and positions of the texts on screen, from one snapshot.
    @MainActor
    private static func signature(_ app: XCUIApplication) -> [String] {
        guard let snapshot = try? app.snapshot() else { return [] }
        let screen = app.windows.firstMatch.frame
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
