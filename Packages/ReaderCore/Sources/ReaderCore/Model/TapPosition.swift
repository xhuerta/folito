import Foundation

/// Estimates which character (and word) of a block lies under a tap, for the word lookup.
///
/// watchOS has no TextKit, so the laid-out lines of a SwiftUI `Text` cannot be queried. Instead the
/// block's measured height gives the number of lines (from the font's line height), the tap's vertical
/// position picks the line, and its horizontal position picks the character on that line, assuming the
/// characters are spread evenly over the lines (as `InBlockPosition` does for the reading line).
///
/// Accuracy: the line is right except within a few points of a line boundary; within the line the
/// estimate is usually the tapped word or its neighbour (proportional glyph widths, ragged line ends),
/// and drifts by a few words at most on the last lines of long paragraphs. The picker opens on that word
/// and the Digital Crown or the arrow buttons fix any miss.
public enum TapPosition {
    /// What is known about a block's layout on screen.
    public struct Layout: Equatable, Sendable {
        /// Width available to the text (the block's width minus its indent), in points.
        public var width: Double
        /// Height of the text (the block's height minus its top padding), in points.
        public var height: Double
        /// Font size of the block, in points.
        public var pointSize: Double
        /// Extra space between lines (`lineSpacing`), in points.
        public var lineSpacing: Double
        /// Extra space between characters (`tracking`), in points.
        public var tracking: Double

        public init(width: Double, height: Double, pointSize: Double, lineSpacing: Double = 0, tracking: Double = 0) {
            self.width = width
            self.height = height
            self.pointSize = pointSize
            self.lineSpacing = lineSpacing
            self.tracking = tracking
        }

        /// Height of one line of the system fonts without line spacing (ascender + descender + leading).
        static let lineHeightFactor = 1.2
        /// Average advance of a character of prose (spaces included) in the system fonts, in ems.
        static let averageCharacterWidthFactor = 0.5

        /// Number of laid-out lines, from the text height: `n * line + (n - 1) * spacing == height`.
        public var lineCount: Int {
            let line = pointSize * Self.lineHeightFactor
            guard line > 0, height.isFinite, height > 0 else { return 1 }
            let spacing = max(lineSpacing, 0)
            return max(1, Int(((height + spacing) / (line + spacing)).rounded()))
        }
    }

    /// Character offset (in `Character`s, `0..<count`) under the point (`x`, `y`) of a block's text.
    public static func characterOffset(x: Double, y: Double, layout: Layout, characterCount count: Int) -> Int {
        guard count > 0, layout.width > 0, layout.height > 0, x.isFinite, y.isFinite else { return 0 }
        let lines = layout.lineCount
        let line = min(max(Int(y / layout.height * Double(lines)), 0), lines - 1)
        // Characters per line from the font, kept consistent with the line count: every line but the
        // last is full, so `(lines - 1) * perLine < count <= lines * perLine`.
        let advance = layout.pointSize * Layout.averageCharacterWidthFactor + layout.tracking
        var perLine = advance > 0 ? layout.width / advance : Double(count)
        let lower = Double(count) / Double(lines)
        perLine = max(perLine, lower)
        if lines > 1 { perLine = min(perLine, Double(count) / Double(lines - 1)) }
        let xFraction = min(max(x / layout.width, 0), 1)
        let offset = Int((Double(line) * perLine + xFraction * perLine).rounded(.down))
        return min(max(offset, 0), count - 1)
    }

    /// Index into `tokens` of the word at `characterOffset` of `text`, or the nearest word to it.
    /// 0 when there are no tokens.
    public static func tokenIndex(forCharacterOffset characterOffset: Int, in text: String,
                                  tokens: [WordToken]) -> Int {
        guard !tokens.isEmpty else { return 0 }
        let clamped = min(max(characterOffset, 0), text.count)
        let utf16 = text.index(text.startIndex, offsetBy: clamped).utf16Offset(in: text)
        var best = 0
        var bestDistance = Int.max
        for (i, token) in tokens.enumerated() {
            let start = token.range.location, end = token.range.location + token.range.length
            let distance = utf16 < start ? start - utf16 : (utf16 >= end ? utf16 - end + 1 : 0)
            if distance == 0 { return i }
            // Ties go to the later word: a tap in the gap after a word usually aims at the next one.
            if distance <= bestDistance { best = i; bestDistance = distance }
            if start > utf16 { break }
        }
        return best
    }
}
