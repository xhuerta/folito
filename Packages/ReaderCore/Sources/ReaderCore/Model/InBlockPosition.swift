import Foundation

/// Math for a reading position inside a block (paragraph), shared by the watch reader and its tests.
///
/// The position is stored as a character offset into the block's text, which survives text-size and
/// font changes. On screen it is mapped to a fraction of the block's laid-out height, assuming the
/// characters are spread evenly over the block's lines (true within a line for prose paragraphs).
public enum InBlockPosition {
    /// Fraction 0...1 of a block's height above the viewport's top edge.
    /// - Parameters:
    ///   - minY: top of the block in the scroll view's coordinate space.
    ///   - maxY: bottom of the block in the same space.
    ///   - viewportTop: where the visible area starts in that space (navigation bar inset).
    public static func fractionScrolledPast(minY: Double, maxY: Double, viewportTop: Double) -> Double {
        let height = maxY - minY
        guard height > 0, height.isFinite else { return 0 }
        return min(max((viewportTop - minY) / height, 0), 1)
    }

    /// Character offset of the text at `fraction` of the block, moved back to the start of its word so
    /// the restored line shows the whole word. Always within `0...text.count`.
    public static func characterOffset(forFraction fraction: Double, in text: String) -> Int {
        let count = text.count
        guard count > 0, fraction.isFinite, fraction > 0 else { return 0 }
        let raw = min(Int((min(fraction, 1) * Double(count)).rounded()), count)
        guard raw > 0, raw < count else { return raw }
        let chars = Array(text)
        var i = raw
        while i > 0, !chars[i - 1].isWhitespace { i -= 1 }
        return i
    }

    /// Fraction 0...1 of the block's height where `offset` starts.
    public static func fraction(forCharacterOffset offset: Int, in text: String) -> Double {
        let count = text.count
        guard count > 0, offset > 0 else { return 0 }
        return min(Double(offset) / Double(count), 1)
    }

    /// Vertical `UnitPoint` anchor for `ScrollViewProxy.scrollTo(_:anchor:)` that puts the point at
    /// `fraction` of the block at the viewport's top edge.
    ///
    /// `scrollTo` aligns the point at `y * blockHeight` inside the block with the point at
    /// `y * viewportHeight` inside the scroll view, so the block's top lands at `y * (V - H)`. Solving
    /// `y * (V - H) == viewportTop - fraction * H` gives the anchor. nil means "use `.top`": no offset
    /// to restore, unknown sizes, or a block exactly as tall as the viewport. The result is clamped to
    /// a sane range (it can leave 0...1 when the saved line is near the end of a long block).
    public static func anchorY(fraction: Double, blockHeight: Double, viewportHeight: Double,
                               viewportTop: Double) -> Double? {
        guard fraction > 0, blockHeight > 0, viewportHeight > 0,
              fraction.isFinite, blockHeight.isFinite, viewportHeight.isFinite else { return nil }
        let span = viewportHeight - blockHeight
        guard abs(span) >= 1 else { return nil }
        let y = (viewportTop - min(fraction, 1) * blockHeight) / span
        return min(max(y, -maxAnchorMagnitude), maxAnchorMagnitude)
    }

    static let maxAnchorMagnitude = 8.0

    /// Corrects an anchor after a jump landed `error` points off (`landedMinY - wantedMinY`): moving the
    /// anchor by `dy` moves the block's top by `dy * (V - H)`.
    public static func correctedAnchorY(_ y: Double, error: Double, blockHeight: Double,
                                        viewportHeight: Double) -> Double {
        let span = viewportHeight - blockHeight
        guard abs(span) >= 1, error.isFinite else { return y }
        return min(max(y - error / span, -maxAnchorMagnitude), maxAnchorMagnitude)
    }

    /// Where the block's top should be for `fraction` of it to sit at the viewport's top edge.
    public static func wantedMinY(fraction: Double, blockHeight: Double, viewportTop: Double) -> Double {
        viewportTop - min(max(fraction, 0), 1) * blockHeight
    }

    /// Points within which a measured position counts as the saved one (about half a line on the watch).
    /// Keeps tiny layout differences from moving the saved offset back a word on every reopen.
    public static let tolerance = 8.0
}
