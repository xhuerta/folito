import CoreGraphics

/// The reader's own left-edge swipe back (#118). Pure; the reader feeds it a finished drag and leaves the book
/// when it returns true.
///
/// watchOS turns off the navigation stack's interactive pop while the navigation bar is hidden (the reader
/// hides it while scrolling, `BarAutoHide`), and with the bar shown the full-width vertical scroll view and
/// the tap gestures on the text claim the touch before the system edge pan does. So the reader recognises the
/// swipe itself, with a simultaneous drag gesture (taps and scrolling still reach the text), and only for a
/// clear rightward drag:
///
/// - the touch starts within `edgeWidth` of the screen's left edge;
/// - it moves right by at least `minDistance`, or is a quick flick of at least `minFlickDistance` whose
///   predicted end is at least `minDistance` to the right;
/// - it is mostly horizontal: the vertical movement is at most `maxSlope` times the horizontal one, so a
///   vertical scroll that happens to start at the edge never leaves the book.
enum EdgeSwipeBack {
    /// Distance from the screen's left edge within which the swipe must start, in points.
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
}
