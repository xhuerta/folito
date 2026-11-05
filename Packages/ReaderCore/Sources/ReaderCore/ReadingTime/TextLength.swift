import Foundation

/// Amount of reading in a piece of text: space-separated words plus CJK characters.
///
/// Chinese and Japanese are written without spaces between words, so counting "words" there would turn a
/// whole paragraph into one or two. Han ideographs and kana are counted one by one instead and read at a
/// characters-per-minute speed (`ReadingSpeed.charactersPerMinute`). Mixed text gets both counts.
public struct TextLength: Codable, Sendable, Equatable {
    public var words: Int
    public var cjkCharacters: Int

    public static let zero = TextLength(words: 0, cjkCharacters: 0)

    public init(words: Int, cjkCharacters: Int) {
        self.words = words
        self.cjkCharacters = cjkCharacters
    }

    public init(_ text: String) {
        var words = 0
        var cjk = 0
        var tokenHasLetter = false
        for scalar in text.unicodeScalars {
            if Self.isCJK(scalar) {
                cjk += 1
                // A word written right before an ideograph ("Swift言語") still ends there.
                if tokenHasLetter { words += 1; tokenHasLetter = false }
            } else if scalar.properties.isWhitespace {
                if tokenHasLetter { words += 1; tokenHasLetter = false }
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                tokenHasLetter = true
            }
            // Punctuation and symbols neither start nor end a word: "don't", "well-known" and "3.5" count once,
            // and a lone dash or "…" counts zero.
        }
        if tokenHasLetter { words += 1 }
        self.words = words
        self.cjkCharacters = cjk
    }

    public var isEmpty: Bool { words == 0 && cjkCharacters == 0 }

    public static func + (lhs: TextLength, rhs: TextLength) -> TextLength {
        TextLength(words: lhs.words + rhs.words, cjkCharacters: lhs.cjkCharacters + rhs.cjkCharacters)
    }

    public static func - (lhs: TextLength, rhs: TextLength) -> TextLength {
        TextLength(words: max(lhs.words - rhs.words, 0),
                   cjkCharacters: max(lhs.cjkCharacters - rhs.cjkCharacters, 0))
    }

    /// Han ideographs (with extensions and compatibility forms), hiragana and katakana (with half-width forms).
    /// Hangul is not included: Korean separates words with spaces.
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF,   // Hiragana, Katakana
             0x31F0...0x31FF,   // Katakana Phonetic Extensions
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF66...0xFF9F,   // Half-width Katakana
             0x20000...0x3FFFF: // CJK Extensions B and later
            return true
        default:
            return false
        }
    }
}
