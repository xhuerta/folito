import Foundation

/// ISBN normalisation for online lookups: hyphens, spaces and a `urn:isbn:` / `ISBN` prefix are removed, the
/// check digit is verified, and ISBN-10 is converted to ISBN-13 (the form Open Library indexes every edition by).
public enum ISBN {
    /// The ISBN-13 of `raw` (ISBN-10 or ISBN-13, with or without separators), or nil when it is not a valid ISBN.
    public static func normalize(_ raw: String) -> String? {
        let compact = compacted(raw)
        if compact.count == 13, isValid13(compact) { return compact }
        if compact.count == 10, isValid10(compact) { return isbn13(fromISBN10: compact) }
        return nil
    }

    /// Digits (and a final X) only, without a `urn:isbn:` or `ISBN` prefix.
    public static func compacted(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        for prefix in ["URN:ISBN:", "ISBN-13:", "ISBN-10:", "ISBN:", "ISBN"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }
        return String(s.filter { $0.isASCII && ($0.isNumber || $0 == "X") })
    }

    /// The valid ISBN-10 in its compact form (digits and X), or nil.
    public static func compactISBN10(_ raw: String) -> String? {
        let compact = compacted(raw)
        return compact.count == 10 && isValid10(compact) ? compact : nil
    }

    public static func isValid10(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 10 else { return false }
        var sum = 0
        for (i, c) in chars.enumerated() {
            let value: Int
            if let d = c.wholeNumberValue, c.isASCII { value = d } else if c == "X" && i == 9 { value = 10 } else { return false }
            sum += value * (10 - i)
        }
        return sum % 11 == 0
    }

    public static func isValid13(_ s: String) -> Bool {
        let digits = s.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
        guard digits.count == 13, s.count == 13, s.hasPrefix("978") || s.hasPrefix("979") else { return false }
        let sum = digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return sum % 10 == 0
    }

    /// ISBN-13 ("978" prefix and a new check digit) of a valid compact ISBN-10.
    public static func isbn13(fromISBN10 isbn10: String) -> String? {
        guard isValid10(isbn10) else { return nil }
        let body = "978" + isbn10.prefix(9)
        let digits = body.compactMap(\.wholeNumberValue)
        let sum = digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return body + String((10 - sum % 10) % 10)
    }
}
