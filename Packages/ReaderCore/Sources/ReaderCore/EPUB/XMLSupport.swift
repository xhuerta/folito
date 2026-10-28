import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Event sink shared by the strict (`XMLParser`) and lenient (tag-soup) readers.
/// Element and attribute names are already lowercased with namespace prefixes stripped;
/// attribute dictionaries additionally keep the full prefixed name (e.g. both `scheme` and `opf:scheme`).
protocol XMLEventHandler: AnyObject {
    func startElement(_ name: String, attributes: [String: String])
    func endElement(_ name: String)
    func characters(_ text: String)
}

enum XMLNames {
    static func element(_ raw: String) -> String {
        let local = raw.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? raw
        return local.lowercased()
    }

    static func attributes(_ raw: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in raw {
            let lower = key.lowercased()
            out[lower] = value
        }
        for (key, value) in out {
            if let idx = key.lastIndex(of: ":") {
                let local = String(key[key.index(after: idx)...])
                if out[local] == nil { out[local] = value }
            }
        }
        return out
    }
}

/// Decodes bytes to text and makes it palatable for the strict XML parser.
enum XMLSanitizer {
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? String(decoding: data, as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? String(decoding: data, as: UTF8.self)
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        // Not valid UTF-8: honour a Latin-1 style declaration, otherwise decode lossily.
        let head = String(decoding: data.prefix(200), as: UTF8.self).lowercased()
        if head.contains("iso-8859-1") || head.contains("windows-125") || head.contains("latin1") {
            return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes the XML declaration and DOCTYPE (which also defuses entity-expansion attacks),
    /// rewrites HTML named entities as numeric references, escapes stray ampersands and drops
    /// characters that are illegal in XML 1.0.
    static func prepare(_ input: String) -> String {
        var s = Substring(input)
        while let first = s.unicodeScalars.first, first == "\u{FEFF}" || first.properties.isWhitespace {
            s = s.dropFirst()
        }
        if s.hasPrefix("<?xml"), let end = s.range(of: "?>") {
            s = s[end.upperBound...]
        }
        let scalars = Array(stripDoctype(String(s)).unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "&" {
                if let (replacement, next) = entityAt(scalars, i) {
                    out.append(contentsOf: replacement.unicodeScalars)
                    i = next
                } else {
                    out.append(contentsOf: "&amp;".unicodeScalars)
                    i += 1
                }
                continue
            }
            if isXMLChar(c) { out.append(c) }
            i += 1
        }
        return String(out)
    }

    /// Replaces every entity reference in `text` with the character it denotes (unknown ones are dropped).
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "&", let (_, next, value) = entityValue(scalars, i) {
                if let value { out.append(contentsOf: value.unicodeScalars) }
                i = next
                continue
            }
            out.append(scalars[i])
            i += 1
        }
        return String(out)
    }

    static func isXMLChar(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x9, 0xA, 0xD: return true
        case 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF: return true
        default: return false
        }
    }

    private static func stripDoctype(_ s: String) -> String {
        guard let start = s.range(of: "<!DOCTYPE", options: .caseInsensitive) else { return s }
        var depth = 0
        var idx = start.upperBound
        while idx < s.endIndex {
            let ch = s[idx]
            if ch == "[" { depth += 1 } else if ch == "]" { depth = max(0, depth - 1) } else if ch == ">" && depth == 0 {
                var out = s
                out.removeSubrange(start.lowerBound...idx)
                return out
            }
            idx = s.index(after: idx)
        }
        return s
    }

    /// Returns the XML-safe replacement for the entity starting at `i` and the index after it.
    private static func entityAt(_ s: [Unicode.Scalar], _ i: Int) -> (String, Int)? {
        guard let (name, next, value) = entityValue(s, i) else { return nil }
        if ["amp", "lt", "gt", "quot", "apos"].contains(name) { return ("&\(name);", next) }
        if let value, let scalar = value.unicodeScalars.first {
            if "&<>\"'".unicodeScalars.contains(scalar) { return ("&#\(scalar.value);", next) }
            return (String(scalar), next)
        }
        return ("", next)
    }

    /// Parses `&name;`, `&#N;` or `&#xH;` at `i`. `value` is nil for unknown/invalid references.
    private static func entityValue(_ s: [Unicode.Scalar], _ i: Int) -> (name: String, next: Int, value: String?)? {
        var j = i + 1
        let limit = min(s.count, i + 34)
        while j < limit, s[j] != ";" , s[j] != "&", s[j] != "<", !s[j].properties.isWhitespace { j += 1 }
        guard j < limit, s[j] == ";", j > i + 1 else { return nil }
        let name = String(String.UnicodeScalarView(s[(i + 1)..<j]))
        let next = j + 1
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let v = value else { return nil }
            if let scalar = Unicode.Scalar(v), isXMLChar(scalar) { return (name, next, String(scalar)) }
            return (name, next, nil)
        }
        guard let first = name.unicodeScalars.first, first.properties.isAlphabetic,
              name.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)) })
        else { return nil }
        switch name {
        case "amp": return (name, next, "&")
        case "lt": return (name, next, "<")
        case "gt": return (name, next, ">")
        case "quot": return (name, next, "\"")
        case "apos": return (name, next, "'")
        default:
            if let cp = HTMLEntities.table[name], let scalar = Unicode.Scalar(cp) { return (name, next, String(scalar)) }
            return (name, next, nil)
        }
    }
}

enum HTMLEntities {
    static let latin1Names: [String] = [
        "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo", "not",
        "shy", "reg", "macr", "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot", "cedil", "sup1",
        "ordm", "raquo", "frac14", "frac12", "frac34", "iquest", "Agrave", "Aacute", "Acirc", "Atilde", "Auml",
        "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute", "Icirc", "Iuml", "ETH",
        "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times", "Oslash", "Ugrave", "Uacute", "Ucirc",
        "Uuml", "Yacute", "THORN", "szlig", "agrave", "aacute", "acirc", "atilde", "auml", "aring", "aelig",
        "ccedil", "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc", "iuml", "eth", "ntilde",
        "ograve", "oacute", "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave", "uacute", "ucirc", "uuml",
        "yacute", "thorn", "yuml",
    ]

    static let table: [String: UInt32] = {
        var t: [String: UInt32] = [:]
        for (i, n) in latin1Names.enumerated() { t[n] = UInt32(160 + i) }
        let extra: [String: UInt32] = [
            "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353, "Yuml": 376, "fnof": 402, "circ": 710,
            "tilde": 732, "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205, "ndash": 8211,
            "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222,
            "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230, "permil": 8240, "prime": 8242,
            "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250, "euro": 8364, "trade": 8482, "larr": 8592, "rarr": 8594,
            "minus": 8722, "infin": 8734, "ne": 8800, "le": 8804, "ge": 8805, "hearts": 9829,
        ]
        t.merge(extra) { a, _ in a }
        return t
    }()
}

/// Bridges `XMLParser` to an `XMLEventHandler`.
private final class StrictXMLDelegate: NSObject, XMLParserDelegate {
    let handler: XMLEventHandler
    init(handler: XMLEventHandler) { self.handler = handler }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        handler.startElement(XMLNames.element(elementName), attributes: XMLNames.attributes(attributeDict))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        handler.endElement(XMLNames.element(elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { handler.characters(string) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        handler.characters(String(decoding: CDATABlock, as: UTF8.self))
    }
}

enum XMLReader {
    /// Strict, well-formedness-checking parse. Returns the parser error, or nil on success.
    static func parseStrict(_ text: String, handler: XMLEventHandler) -> Error? {
        let parser = XMLParser(data: Data(XMLSanitizer.prepare(text).utf8))
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = StrictXMLDelegate(handler: handler)
        parser.delegate = delegate
        if parser.parse() { return nil }
        return parser.parserError ?? EPUBError.malformedXML("unknown XML error")
    }

    /// Strict parse first; on failure a fresh handler from `make` is fed by the lenient reader.
    /// - Returns: the handler that received a complete event stream, and whether leniency was needed.
    static func parse<H: XMLEventHandler>(_ text: String, make: () -> H) -> (handler: H, wasLenient: Bool, error: Error?) {
        let strict = make()
        guard let error = parseStrict(text, handler: strict) else { return (strict, false, nil) }
        let lenient = make()
        LenientXMLReader.run(text, handler: lenient)
        return (lenient, true, error)
    }
}

/// Forgiving tag-soup reader for chapters that are not well-formed XML:
/// handles void elements, mismatched/unclosed tags, bare ampersands and unknown entities.
enum LenientXMLReader {
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Elements nested deeper than this are dropped by the lenient reader.
    static let maxDepth = 256

    private static let autoClosing: Set<String> = ["p", "li", "dt", "dd", "tr", "td", "th", "option"]

    static func run(_ input: String, handler: XMLEventHandler) {
        let s = Array(XMLSanitizer.prepareLenient(input).unicodeScalars)
        var i = 0
        var open: [String] = []
        var text = String.UnicodeScalarView()
        let commentOpen = Array("<!--".unicodeScalars), cdataOpen = Array("<![CDATA[".unicodeScalars)

        func flush() {
            if !text.isEmpty {
                handler.characters(XMLSanitizer.decodeEntities(String(text)))
                text = String.UnicodeScalarView()
            }
        }
        func matches(_ p: [Unicode.Scalar], at k: Int) -> Bool {
            guard k >= 0, k + p.count <= s.count else { return false }
            for (o, c) in p.enumerated() where s[k + o] != c { return false }
            return true
        }
        func find(_ pattern: String, from: Int) -> Int? {
            let p = Array(pattern.unicodeScalars)
            guard !p.isEmpty, s.count >= p.count else { return nil }
            var k = from
            while k <= s.count - p.count {
                if s[k] == p[0], matches(p, at: k) { return k }
                k += 1
            }
            return nil
        }
        func isNameEnd(_ c: Unicode.Scalar) -> Bool { c.properties.isWhitespace || c == "/" || c == ">" || c == "=" }

        while i < s.count {
            let c = s[i]
            guard c == "<", i + 1 < s.count else {
                text.append(c)
                i += 1
                continue
            }
            let n = s[i + 1]
            if n == "!" || n == "?" {
                flush()
                if matches(commentOpen, at: i) {
                    i = (find("-->", from: i + 4)).map { $0 + 3 } ?? s.count
                } else if matches(cdataOpen, at: i) {
                    let end = find("]]>", from: i + 9) ?? s.count
                    handler.characters(String(String.UnicodeScalarView(s[(i + 9)..<min(end, s.count)])))
                    i = min(end + 3, s.count)
                } else {
                    i = (find(">", from: i)).map { $0 + 1 } ?? s.count
                }
            } else if n == "/" {
                flush()
                var j = i + 2
                var name = String.UnicodeScalarView()
                while j < s.count, !isNameEnd(s[j]) { name.append(s[j]); j += 1 }
                while j < s.count, s[j] != ">" { j += 1 }
                i = min(j + 1, s.count)
                let normalized = XMLNames.element(String(name))
                if let at = open.lastIndex(of: normalized) {
                    while open.count > at {
                        handler.endElement(open.removeLast())
                    }
                }
            } else if n.properties.isAlphabetic {
                flush()
                var j = i + 1
                var name = String.UnicodeScalarView()
                while j < s.count, !isNameEnd(s[j]) { name.append(s[j]); j += 1 }
                var attrs: [String: String] = [:]
                var selfClosing = false
                attrLoop: while j < s.count {
                    while j < s.count, s[j].properties.isWhitespace { j += 1 }
                    guard j < s.count else { break }
                    if s[j] == ">" { j += 1; break }
                    if s[j] == "/" { selfClosing = true; j += 1; continue }
                    var key = String.UnicodeScalarView()
                    while j < s.count, !isNameEnd(s[j]) { key.append(s[j]); j += 1 }
                    if key.isEmpty { j += 1; continue attrLoop }
                    while j < s.count, s[j].properties.isWhitespace { j += 1 }
                    var value = String.UnicodeScalarView()
                    if j < s.count, s[j] == "=" {
                        j += 1
                        while j < s.count, s[j].properties.isWhitespace { j += 1 }
                        if j < s.count, s[j] == "\"" || s[j] == "'" {
                            let quote = s[j]
                            j += 1
                            while j < s.count, s[j] != quote { value.append(s[j]); j += 1 }
                            j += 1
                        } else {
                            while j < s.count, !s[j].properties.isWhitespace, s[j] != ">" { value.append(s[j]); j += 1 }
                        }
                    }
                    attrs[String(key)] = XMLSanitizer.decodeEntities(String(value))
                }
                i = min(j, s.count)
                let normalized = XMLNames.element(String(name))
                if autoClosing.contains(normalized), open.last == normalized {
                    handler.endElement(open.removeLast())  // HTML: <p>a<p>b closes the first <p>
                }
                if open.count >= Self.maxDepth, !selfClosing, !voidElements.contains(normalized) {
                    continue  // pathological nesting: drop the tag (its end tag then matches nothing)
                }
                handler.startElement(normalized, attributes: XMLNames.attributes(attrs))
                if selfClosing || voidElements.contains(normalized) {
                    handler.endElement(normalized)
                } else if normalized == "script" || normalized == "style" {
                    let end = find("</" + String(name), from: i) ?? s.count
                    i = end
                    open.append(normalized)
                } else {
                    open.append(normalized)
                }
            } else {
                text.append(c)
                i += 1
            }
        }
        flush()
        while let name = open.popLast() { handler.endElement(name) }
    }
}

extension XMLSanitizer {
    /// For the lenient reader: only strips declaration/doctype and illegal characters; entities are decoded later.
    static func prepareLenient(_ input: String) -> String {
        var s = Substring(input)
        while let first = s.unicodeScalars.first, first == "\u{FEFF}" || first.properties.isWhitespace {
            s = s.dropFirst()
        }
        if s.hasPrefix("<?xml"), let end = s.range(of: "?>") { s = s[end.upperBound...] }
        return String(String.UnicodeScalarView(stripDoctype(String(s)).unicodeScalars.filter { isXMLChar($0) }))
    }
}

/// Minimal DOM used for the small metadata documents (container, OPF, NCX, nav).
final class XMLNode {
    let name: String
    let attributes: [String: String]
    var children: [XMLNode] = []
    var text = ""
    weak var parent: XMLNode?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }

    /// All descendants with the given name, in document order.
    func descendants(_ name: String) -> [XMLNode] {
        var out: [XMLNode] = []
        for c in children {
            if c.name == name { out.append(c) }
            out.append(contentsOf: c.descendants(name))
        }
        return out
    }

    var textContent: String { text + children.map { $0.textContent }.joined() }

    var trimmedText: String {
        textContent.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

final class XMLTreeBuilder: XMLEventHandler {
    let root = XMLNode(name: "#document", attributes: [:])
    private var current: XMLNode
    private var depth = 0
    private var transparent = 0   // elements beyond maxDepth are flattened into their ancestor
    static let maxDepth = 128

    init() { current = root }

    func startElement(_ name: String, attributes: [String: String]) {
        if transparent > 0 || depth >= Self.maxDepth { transparent += 1; return }
        depth += 1
        let node = XMLNode(name: name, attributes: attributes)
        node.parent = current
        current.children.append(node)
        current = node
    }

    func endElement(_ name: String) {
        if transparent > 0 { transparent -= 1; return }
        depth -= 1
        if let p = current.parent { current = p }
    }

    func characters(_ text: String) { current.text += text }

    static func parse(_ data: Data, what: String) throws -> XMLNode {
        let result = XMLReader.parse(XMLSanitizer.decode(data)) { XMLTreeBuilder() }
        guard let rootElement = result.handler.root.children.first else {
            throw EPUBError.malformedXML("\(what): \(result.error?.localizedDescription ?? "no root element")")
        }
        return rootElement
    }
}
