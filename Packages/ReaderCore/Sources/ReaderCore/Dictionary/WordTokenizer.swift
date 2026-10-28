import Foundation

/// A word found in a block of text. `range` is a UTF-16 range into the original string, which is what
/// `StyleSpan` and `NSRange`/`AttributedString` bridging use, so it is safe with emoji and combining marks.
public struct WordToken: Equatable, Sendable {
    public let text: String
    public let range: NSRange

    public init(text: String, range: NSRange) {
        self.text = text
        self.range = range
    }
}

public enum WordTokenizer {
    private static let apostrophes: Set<Unicode.Scalar> = ["'", "\u{2019}", "\u{02BC}", "\u{2018}"]
    private static let hyphens: Set<Unicode.Scalar> = ["-", "\u{2010}", "\u{2011}"]
    private static let ignorable: Set<Unicode.Scalar> = ["\u{00AD}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}"]

    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.letters.contains(s) || CharacterSet.nonBaseCharacters.contains(s)
    }

    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        isLetter(s) || CharacterSet.decimalDigits.contains(s) || ignorable.contains(s)
    }

    /// Words of `text` in reading order. A word is a run of letters/digits that may contain apostrophes
    /// and hyphens *between* word characters ("don't", "well-known", "l’homme"). Tokens without any letter
    /// (numbers, "1984") are skipped: there is nothing to look up.
    public static func tokens(in text: String) -> [WordToken] {
        let scalars = Array(text.unicodeScalars)
        // UTF-16 offset of each scalar (+ end).
        var offsets = [Int](); offsets.reserveCapacity(scalars.count + 1)
        var o = 0
        for s in scalars { offsets.append(o); o += s.value > 0xFFFF ? 2 : 1 }
        offsets.append(o)

        var result: [WordToken] = []
        var i = 0
        while i < scalars.count {
            guard isWordScalar(scalars[i]), !ignorable.contains(scalars[i]) else { i += 1; continue }
            var j = i + 1
            while j < scalars.count {
                let s = scalars[j]
                if isWordScalar(s) { j += 1; continue }
                if (apostrophes.contains(s) || hyphens.contains(s)), j + 1 < scalars.count,
                   isWordScalar(scalars[j + 1]), !ignorable.contains(scalars[j + 1]) {
                    j += 2; continue
                }
                break
            }
            let slice = scalars[i..<j]
            if slice.contains(where: { isLetter($0) }) {
                var str = String.UnicodeScalarView()
                str.append(contentsOf: slice)
                result.append(WordToken(text: String(str),
                                        range: NSRange(location: offsets[i], length: offsets[j] - offsets[i])))
            }
            i = j
        }
        return result
    }

    /// Swift range of a token in `text`; nil if it does not fit (stale token).
    public static func range(of token: WordToken, in text: String) -> Range<String.Index>? {
        Range(token.range, in: text)
    }

    /// Index of the token containing, or nearest after, UTF-16 `offset` (nil if there are no tokens).
    public static func tokenIndex(at offset: Int, in tokens: [WordToken]) -> Int? {
        guard !tokens.isEmpty else { return nil }
        for (i, t) in tokens.enumerated() where NSMaxRange(t.range) > offset { return i }
        return tokens.count - 1
    }
}

/// The text around a selected word, for the cursor UI: a few neighbouring words on each side.
public struct WordContext: Equatable, Sendable {
    public let before: String
    public let word: String
    public let after: String
    public let hasMoreBefore: Bool
    public let hasMoreAfter: Bool

    public init(before: String, word: String, after: String, hasMoreBefore: Bool, hasMoreAfter: Bool) {
        self.before = before
        self.word = word
        self.after = after
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
    }

    /// `radius` words on each side, taken verbatim from `text` (punctuation between words is kept).
    public static func make(text: String, tokens: [WordToken], index: Int, radius: Int = 4) -> WordContext? {
        guard tokens.indices.contains(index) else { return nil }
        let utf16 = text.utf16
        func slice(_ from: Int, _ to: Int) -> String {
            guard from < to, let lo = utf16.index(utf16.startIndex, offsetBy: from, limitedBy: utf16.endIndex),
                  let hi = utf16.index(utf16.startIndex, offsetBy: to, limitedBy: utf16.endIndex) else { return "" }
            return String(text[lo..<hi])
        }
        let first = max(0, index - radius), last = min(tokens.count - 1, index + radius)
        let cur = tokens[index].range
        return WordContext(
            before: slice(tokens[first].range.location, cur.location),
            word: tokens[index].text,
            after: slice(NSMaxRange(cur), NSMaxRange(tokens[last].range)),
            hasMoreBefore: first > 0,
            hasMoreAfter: last < tokens.count - 1)
    }
}
