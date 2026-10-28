import Foundation

/// Minimal HTML -> plain text for dictionary definitions. Not a general HTML parser: it handles the
/// fragments Wiktionary's REST API returns (links, spans, `<b>`, `<i>`, nested `<ol>` sub-senses, `<link>`).
public enum HTMLText {
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "\u{2013}",
        "mdash": "\u{2014}", "hellip": "\u{2026}", "laquo": "\u{00AB}", "raquo": "\u{00BB}", "lsquo": "\u{2018}",
        "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}", "shy": "", "middot": "\u{00B7}",
    ]

    /// Plain text of `html`: tags removed, entities decoded, whitespace collapsed. Content of `<style>`,
    /// `<script>` and (if `dropNestedLists`) `<ol>`/`<ul>` blocks is dropped.
    public static func plain(_ html: String, dropNestedLists: Bool = false) -> String {
        var source = html
        for tag in ["style", "script"] { source = removeBlocks(tag, from: source) }
        if dropNestedLists { for tag in ["ol", "ul"] { source = removeBlocks(tag, from: source) } }
        var out = ""
        out.reserveCapacity(source.count)
        var i = source.startIndex
        while i < source.endIndex {
            let c = source[i]
            if c == "<" {
                // A tag only if it looks like one; otherwise a literal "<".
                if let close = source[i...].firstIndex(of: ">"),
                   let next = source[source.index(after: i)..<close].first,
                   next.isLetter || next == "/" || next == "!" {
                    let name = tagName(source[source.index(after: i)..<close])
                    if ["br", "li", "p", "div"].contains(name) { out.append(" ") }
                    i = source.index(after: close)
                    continue
                }
            } else if c == "&" {
                if let semi = source[i...].prefix(12).firstIndex(of: ";") {
                    let body = String(source[source.index(after: i)..<semi])
                    if let decoded = decodeEntity(body) {
                        out.append(decoded)
                        i = source.index(after: semi)
                        continue
                    }
                }
            }
            out.append(c)
            i = source.index(after: i)
        }
        return collapse(out)
    }

    private static func tagName(_ inner: Substring) -> String {
        var s = inner
        if s.first == "/" { s = s.dropFirst() }
        return String(s.prefix(while: { $0.isLetter || $0.isNumber })).lowercased()
    }

    private static func decodeEntity(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" { value = UInt32(digits.dropFirst(), radix: 16) }
            else { value = UInt32(digits, radix: 10) }
            guard let v = value, let scalar = Unicode.Scalar(v) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[body]
    }

    /// Removes `<tag ...>...</tag>` including nested same-name tags.
    private static func removeBlocks(_ tag: String, from s: String) -> String {
        let lower = s.lowercased()
        // Lowercasing can change the length (e.g. "İ"); only use the fast path when indices still line up.
        guard lower.utf8.count == s.utf8.count else { return s }
        let open = "<" + tag, close = "</" + tag + ">"
        var result = ""
        var cursor = s.startIndex
        var searchFrom = lower.startIndex
        while let start = lower.range(of: open, range: searchFrom..<lower.endIndex) {
            // Must be followed by whitespace, '>' or '/' to be this tag and not e.g. <olive>.
            let after = start.upperBound
            guard after < lower.endIndex, " \t\n>/".contains(lower[after]) else { searchFrom = start.upperBound; continue }
            result += s[cursor..<start.lowerBound]
            var depth = 1
            var scan = after
            var end = lower.endIndex
            while depth > 0 {
                let nextOpen = lower.range(of: open, range: scan..<lower.endIndex)
                guard let nextClose = lower.range(of: close, range: scan..<lower.endIndex) else { end = lower.endIndex; depth = 0; break }
                if let o = nextOpen, o.lowerBound < nextClose.lowerBound {
                    depth += 1; scan = o.upperBound
                } else {
                    depth -= 1; scan = nextClose.upperBound
                    if depth == 0 { end = nextClose.upperBound }
                }
            }
            cursor = end
            searchFrom = end
        }
        result += s[cursor...]
        return result
    }

    private static func collapse(_ s: String) -> String {
        var out = ""
        var lastSpace = true
        for c in s {
            if c.isWhitespace || c == "\u{00A0}" {
                if !lastSpace { out.append(" "); lastSpace = true }
            } else {
                out.append(c); lastSpace = false
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        // "word ." produced by removed inline tags.
        for p in [" .", " ,", " ;", " :", " )", "( "] {
            let fixed = p.trimmingCharacters(in: .whitespaces)
            out = out.replacingOccurrences(of: p, with: fixed)
        }
        return out
    }
}
