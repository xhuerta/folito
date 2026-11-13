import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

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
    ///
    /// Chinese and Japanese do not separate words with spaces, so a run holding Han or kana ("吾輩は猫である")
    /// is segmented further: with NaturalLanguage's word tokenizer where it exists (`language`, a BCP 47 code
    /// such as "ja" or "zh-Hans", helps it), otherwise one word per Han character or hiragana and one per
    /// run of katakana.
    public static func tokens(in text: String, language: String? = nil) -> [WordToken] {
        var result: [WordToken] = []
        for token in runs(in: text) {
            if token.text.unicodeScalars.contains(where: isCJK) {
                result += segmentCJK(token, language: language)
            } else {
                result.append(token)
            }
        }
        return result
    }

    /// Han ideographs, kana and the Japanese iteration marks.
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        isHan(s) || isHiragana(s) || isKatakana(s)
    }

    private static func isHan(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3005...0x3007, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF: return true
        default: return false
        }
    }

    private static func isHiragana(_ s: Unicode.Scalar) -> Bool { (0x3040...0x309F).contains(s.value) }

    private static func isKatakana(_ s: Unicode.Scalar) -> Bool {
        (0x30A0...0x30FF).contains(s.value) || (0x31F0...0x31FF).contains(s.value) || (0xFF66...0xFF9F).contains(s.value)
    }

    /// Splits one letter run that holds Chinese or Japanese into words; ranges stay relative to the full text.
    private static func segmentCJK(_ token: WordToken, language: String?) -> [WordToken] {
        let run = token.text
        var pieces: [(start: Int, end: Int)] = []   // UTF-16 offsets into `run`
        #if canImport(NaturalLanguage)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = run
        if let nl = nlLanguage(language, run: run) { tokenizer.setLanguage(nl) }
        tokenizer.enumerateTokens(in: run.startIndex..<run.endIndex) { range, _ in
            pieces.append((run.utf16.distance(from: run.utf16.startIndex, to: range.lowerBound),
                           run.utf16.distance(from: run.utf16.startIndex, to: range.upperBound)))
            return true
        }
        #else
        pieces = fallbackSegments(run)
        #endif
        let utf16 = Array(run.utf16)
        return pieces.compactMap { p in
            guard p.start < p.end, p.end <= utf16.count else { return nil }
            let text = String(decoding: utf16[p.start..<p.end], as: UTF16.self)
            guard text.unicodeScalars.contains(where: { isLetter($0) }) else { return nil }
            return WordToken(text: text, range: NSRange(location: token.range.location + p.start, length: p.end - p.start))
        }
    }

    #if canImport(NaturalLanguage)
    private static func nlLanguage(_ code: String?, run: String) -> NLLanguage? {
        guard let code, let primary = code.split(separator: "-").first?.lowercased() else {
            // No language: kana can only be Japanese; leave Han-only text to the tokenizer's own guess.
            return run.unicodeScalars.contains(where: { isHiragana($0) || isKatakana($0) }) ? .japanese : nil
        }
        if primary == "zh" {
            let traditional = ["Hant", "TW", "HK", "MO"].contains { code.contains($0) }
            return traditional ? .traditionalChinese : .simplifiedChinese
        }
        return NLLanguage(rawValue: primary)
    }
    #endif

    /// Word boundaries without a dictionary: each Han character and each hiragana is a word, a run of katakana
    /// (loanwords, "ニャーニャー") is one, and any other letters (a Latin "Q" in "阿Q正传") stay together.
    /// Combining and invisible marks stay with the character before them.
    static func fallbackSegments(_ run: String) -> [(start: Int, end: Int)] {
        enum Kind { case single, katakana, other }
        var pieces: [(start: Int, end: Int)] = []
        var current: (start: Int, end: Int, kind: Kind)?
        var offset = 0
        for s in run.unicodeScalars {
            let width = s.value > 0xFFFF ? 2 : 1
            defer { offset += width }
            if let c = current, CharacterSet.nonBaseCharacters.contains(s) || ignorable.contains(s) {
                current = (c.start, offset + width, c.kind)
                continue
            }
            let kind: Kind = isHan(s) || isHiragana(s) ? .single : isKatakana(s) ? .katakana : .other
            if let c = current, kind != .single, c.kind == kind {
                current = (c.start, offset + width, kind)
                continue
            }
            if let c = current { pieces.append((c.start, c.end)) }
            current = (offset, offset + width, kind)
        }
        if let c = current { pieces.append((c.start, c.end)) }
        return pieces
    }

    /// Letter runs of `text` (the space-separated words), before any CJK segmentation.
    private static func runs(in text: String) -> [WordToken] {
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
