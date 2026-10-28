import Foundation

/// Turns a tapped/selected token into dictionary headwords to try, most specific first.
public enum WordNormalizer {
    private static let apostropheVariants: [Character] = ["\u{2019}", "\u{02BC}", "\u{2018}", "`", "\u{00B4}"]
    private static let dropped: Set<Character> = ["\u{00AD}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}"]

    /// NFC, soft hyphens removed, typographic apostrophes -> `'`, hyphen variants -> `-`, surrounding
    /// punctuation/quotes stripped, trailing possessive `'s` removed. Case is preserved.
    public static func clean(_ raw: String) -> String {
        var chars: [Character] = []
        for c in raw.precomposedStringWithCanonicalMapping {
            if dropped.contains(c) { continue }
            if apostropheVariants.contains(c) { chars.append("'"); continue }
            if c == "\u{2010}" || c == "\u{2011}" { chars.append("-"); continue }
            chars.append(c)
        }
        func isCore(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        while let f = chars.first, !isCore(f) { chars.removeFirst() }
        while let l = chars.last, !isCore(l) { chars.removeLast() }
        var s = String(chars)
        if s.count > 2, s.hasSuffix("'s") || s.hasSuffix("'S") { s.removeLast(2) }
        return s
    }

    /// Primary language subtag of a BCP-47 tag, lowercased; 3-letter ISO 639-2 codes of common languages
    /// are mapped to their 2-letter form. nil/empty/garbage -> "en".
    public static func primaryLanguage(_ tag: String?) -> String {
        guard let tag, !tag.isEmpty else { return "en" }
        let primary = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        guard primary.count >= 2, primary.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "en" }
        return iso639_2to1[primary] ?? primary
    }

    private static let iso639_2to1: [String: String] = [
        "eng": "en", "spa": "es", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "ita": "it",
        "por": "pt", "nld": "nl", "dut": "nl", "rus": "ru", "pol": "pl", "swe": "sv", "dan": "da",
        "nor": "no", "fin": "fi", "ces": "cs", "cze": "cs", "lat": "la", "ell": "el", "gre": "el",
        "tur": "tr", "cat": "ca", "jpn": "ja", "zho": "zh", "chi": "zh", "kor": "ko", "ara": "ar",
        "heb": "he", "hun": "hu", "ron": "ro", "rum": "ro", "ukr": "uk",
    ]

    /// Headwords to try for `token`, in order, without duplicates and bounded (each costs a request):
    /// the cleaned form, its lowercase form, a capitalised form for German nouns, then simple
    /// plural / -ed / -ing reductions of the lowercase form as a last resort.
    public static func candidates(for token: String, language: String? = nil, limit: Int = 5) -> [String] {
        let lang = primaryLanguage(language)
        let cleaned = clean(token)
        guard !cleaned.isEmpty else { return [] }
        var out: [String] = []
        func add(_ s: String) {
            if !s.isEmpty, !out.contains(s) { out.append(s) }
        }
        add(cleaned)
        let lower = cleaned.lowercased()
        add(lower)
        if lang == "de", let first = lower.first {
            add(String(first).uppercased() + lower.dropFirst())
        }
        for stem in stems(of: lower, language: lang) { add(stem) }
        return Array(out.prefix(limit))
    }

    /// Crude lemma guesses. Only used after the exact forms were not found, so wrong guesses cost one
    /// failed request, never a wrong answer for a word that exists.
    static func stems(of w: String, language: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) { if s.count >= 2, s != w, !out.contains(s) { out.append(s) } }
        let n = w.count
        switch language {
        case "en":
            if n > 4, w.hasSuffix("ies") { add(String(w.dropLast(3)) + "y") }
            if n > 4, w.hasSuffix("ves") { add(String(w.dropLast(3)) + "f"); add(String(w.dropLast(3)) + "fe") }
            if n > 4, w.hasSuffix("es") { add(String(w.dropLast(2))) }
            if n > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { add(String(w.dropLast())) }
            if n > 4, w.hasSuffix("ied") { add(String(w.dropLast(3)) + "y") }
            if n > 4, w.hasSuffix("ed") {
                let base = String(w.dropLast(2))
                if let l = base.last, base.dropLast().last == l, !"aeiou".contains(l) { add(String(base.dropLast())) }
                add(base)
                add(String(w.dropLast()))   // liked -> like
            }
            if n > 5, w.hasSuffix("ing") {
                let base = String(w.dropLast(3))
                if let l = base.last, base.dropLast().last == l, !"aeiou".contains(l) { add(String(base.dropLast())) }
                add(base)
                add(base + "e")             // making -> make
            }
        case "es", "pt", "fr", "it", "ca":
            if n > 4, w.hasSuffix("es") { add(String(w.dropLast(2))) }
            if n > 3, w.hasSuffix("s") { add(String(w.dropLast())) }
        default:
            break
        }
        return out
    }
}
