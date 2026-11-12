import CoreGraphics

/// The reader's own left-edge swipe back (#118). Pure; the reader feeds it a finished drag and leaves the book
/// when it returns true.
///
/// watchOS turns off the navigation stack's interactive pop while the navigation bar is hidden (the reader
/// hides it while scrolling, `BarAutoHide`), and with the bar shown the full-width vertical scroll view and
/// the tap gestures on the text claim the touch before the system edge pan does. So the reader recognises the
/// swipe itself, on a thin transparent strip along the left edge of the screen (an overlay above the scroll
/// view; a drag gesture on the scroll view or any ancestor, even a simultaneous one, stops the watchOS scroll
/// view from panning), and only for a clear rightward drag:
///
/// - the touch starts within `edgeWidth` of the screen's left edge;
/// - it moves right by at least `minDistance`, or is a quick flick of at least `minFlickDistance` whose
///   predicted end is at least `minDistance` to the right;
/// - it is mostly horizontal: the vertical movement is at most `maxSlope` times the horizontal one, so a
///   vertical scroll that happens to start at the edge never leaves the book.
///
/// The strip sits over the start of every line, so it forwards taps to the text (`tapTarget`): a tap in the
/// strip looks up the first word of the line under it like a tap on the block itself. A vertical drag that
/// starts in the strip does not scroll (SwiftUI cannot hand a touch the overlay received back to the scroll
/// view); the strip is 12 pt, and the crown and touches anywhere else scroll as usual.
enum EdgeSwipeBack {
    /// Width of the strip along the left edge where the swipe must start, in points.
    static let edgeWidth: CGFloat = 12
    /// Rightward travel that leaves the book (about a quarter of a 44 mm screen).
    static let minDistance: CGFloat = 44
    /// Shortest travel for a flick judged by its predicted end.
    static let minFlickDistance: CGFloat = 20
    /// Largest |dy| / dx accepted (about 31 degrees off horizontal).
    static let maxSlope: CGFloat = 0.6

    /// - Parameters:
    ///   - startX: where the touch went down, in screen coordinates.
    ///   - screenMinX: the screen's left edge in the same coordinates (0 for the global space).
    ///   - translation: how far the touch moved.
    ///   - predictedEndTranslation: where the system predicts the movement would end, if known.
    static func isBackSwipe(startX: CGFloat, screenMinX: CGFloat = 0, translation: CGSize,
                            predictedEndTranslation: CGSize? = nil) -> Bool {
        guard startX - screenMinX <= edgeWidth else { return false }
        let dx = translation.width
        guard dx > 0, abs(translation.height) <= dx * maxSlope else { return false }
        if dx >= minDistance { return true }
        guard dx >= minFlickDistance, let predicted = predictedEndTranslation else { return false }
        return predicted.width >= minDistance && abs(predicted.height) <= predicted.width * maxSlope
    }

    /// Where a tap in the edge strip lands in the text: the block under it and the tap in that block's own
    /// coordinates (what the block's `onTapGesture` would have received), or nil over no block (paragraph
    /// spacing, above the first or below the last block).
    ///
    /// - Parameters:
    ///   - point: the tap, in global coordinates.
    ///   - scrollOrigin: the scroll view's origin in global coordinates. `frames` are in the scroll view's own
    ///     named coordinate space, whose origin is this point (it does not move while scrolling).
    ///   - contentMinX: the blocks' leading edge in the scroll view's space (the text's horizontal margin).
    ///   - frames: the on-screen block frames (`BlockFramesKey`).
    static func tapTarget(at point: CGPoint, scrollOrigin: CGPoint, contentMinX: CGFloat,
                          frames: [Int: BlockFrame]) -> (index: Int, location: CGPoint)? {
        let y = point.y - scrollOrigin.y
        guard let hit = frames.filter({ y >= $0.value.minY && y < $0.value.maxY })
            .min(by: { $0.key < $1.key }) else { return nil }
        // The strip covers the margin, left of the text: clamp to the line's first character.
        let x = max(0, point.x - scrollOrigin.x - contentMinX)
        return (hit.key, CGPoint(x: x, y: y - hit.value.minY))
    }
}
