import Foundation

/// A block as extracted from one XHTML document, before xpointers and global offsets are assigned.
struct RawBlock: Equatable {
    var text: String
    var style: BlockStyle
    var spans: [StyleSpan]
    /// Element path below `<body>`.
    var path: [PathStep]
}

/// Accumulates whitespace-collapsed text with inline style spans (UTF-16 ranges).
struct TextAccumulator {
    private(set) var text = ""
    private(set) var spans: [StyleSpan] = []
    private var utf16Length = 0
    private var pendingSeparator: Character?
    private var lastBold = false
    private var lastItalic = false

    var isEmpty: Bool { text.isEmpty }

    mutating func append(_ string: String, bold: Bool, italic: Bool) {
        for ch in string {
            let isSpace = ch.isWhitespace && ch != "\u{00A0}"
            if isSpace {
                if !text.isEmpty, pendingSeparator == nil { pendingSeparator = " " }
            } else {
                if let sep = pendingSeparator {
                    // A separator is only emphasised when both neighbours are.
                    put(sep, bold: bold && lastBold, italic: italic && lastItalic)
                    pendingSeparator = nil
                }
                put(ch, bold: bold, italic: italic)
            }
        }
    }

    mutating func lineBreak() {
        if !text.isEmpty { pendingSeparator = "\n" }
    }

    private mutating func put(_ ch: Character, bold: Bool, italic: Bool) {
        let len = ch.utf16.count
        if bold || italic {
            if let last = spans.last, last.bold == bold, last.italic == italic, last.location + last.length == utf16Length {
                spans[spans.count - 1].length += len
            } else {
                spans.append(StyleSpan(location: utf16Length, length: len, bold: bold, italic: italic))
            }
        }
        text.append(ch)
        utf16Length += len
        lastBold = bold
        lastItalic = italic
    }
}

/// Walks the XHTML event stream and emits one block per innermost text-bearing block element.
/// Mixed content (`<div>a<p>b</p>c</div>`) yields "a", "b", "c" as three blocks, none duplicated.
final class BlockExtractor: XMLEventHandler {
    private final class Frame {
        let name: String
        let path: [PathStep]
        let isBlock: Bool
        let style: BlockStyle
        var childCounts: [String: Int] = [:]
        var buffer = TextAccumulator()
        var bold = false
        var italic = false

        init(name: String, path: [PathStep], isBlock: Bool, style: BlockStyle) {
            self.name = name
            self.path = path
            self.isBlock = isBlock
            self.style = style
        }
    }

    static let inlineElements: Set<String> = [
        "a", "span", "b", "strong", "i", "em", "u", "small", "big", "sub", "sup", "code", "cite", "abbr", "q",
        "mark", "s", "strike", "del", "ins", "font", "tt", "var", "kbd", "samp", "dfn", "time", "bdi", "bdo",
        "ruby", "rt", "rp", "label", "data", "wbr", "img", "br", "nobr",
    ]
    static let skippedElements: Set<String> = [
        "script", "style", "head", "svg", "math", "object", "audio", "video", "canvas", "noscript", "template",
    ]

    private static let invisible: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{00A0}\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{00AD}")
        return set
    }()

    private(set) var blocks: [RawBlock] = []
    private var stack: [Frame] = []
    private var inBody = false
    private var bodyDone = false
    private var skipDepth = 0
    /// Elements nested deeper than `maxDepth` are flattened into their ancestor (keeps paths and memory bounded).
    static let maxDepth = 256
    private var transparentDepth = 0
    private var boldDepth = 0
    private var italicDepth = 0

    func startElement(_ name: String, attributes: [String: String]) {
        if !inBody {
            if name == "body", !bodyDone {
                inBody = true
                stack = [Frame(name: "body", path: [], isBlock: true, style: .paragraph)]
            }
            return
        }
        if skipDepth > 0 { skipDepth += 1; return }
        if transparentDepth > 0 || stack.count > Self.maxDepth { transparentDepth += 1; return }
        let parent = stack[stack.count - 1]
        let index = (parent.childCounts[name] ?? 0) + 1
        parent.childCounts[name] = index  // counted over ALL element siblings, as crengine does
        if Self.skippedElements.contains(name) { skipDepth = 1; return }

        let isBlock = !Self.inlineElements.contains(name)
        if isBlock { flush(nearestBlock()) }
        if name == "br" {
            nearestBlock().buffer.lineBreak()
        }
        let frame = Frame(name: name, path: parent.path + [PathStep(name: name, index: index)],
                          isBlock: isBlock, style: isBlock ? style(for: name, parent: parent) : .paragraph)
        if name == "b" || name == "strong" { frame.bold = true; boldDepth += 1 }
        if name == "i" || name == "em" { frame.italic = true; italicDepth += 1 }
        stack.append(frame)
    }

    func endElement(_ name: String) {
        guard inBody else { return }
        if skipDepth > 0 { skipDepth -= 1; return }
        if transparentDepth > 0 { transparentDepth -= 1; return }
        guard stack.count > 1 else {
            // closing </body>
            if name == "body" { finish() }
            return
        }
        let frame = stack.removeLast()
        if frame.isBlock { flush(frame) }
        if frame.bold { boldDepth -= 1 }
        if frame.italic { italicDepth -= 1 }
    }

    func characters(_ text: String) {
        guard inBody, skipDepth == 0 else { return }
        nearestBlock().buffer.append(text, bold: boldDepth > 0, italic: italicDepth > 0)
    }

    /// Flushes everything still open. Safe to call more than once.
    func finish() {
        while let frame = stack.popLast() { flush(frame) }
        inBody = false
        bodyDone = true
    }

    private func nearestBlock() -> Frame {
        for frame in stack.reversed() where frame.isBlock { return frame }
        return stack[0]
    }

    private func flush(_ frame: Frame) {
        guard !frame.buffer.isEmpty else { return }
        // Blocks that only hold invisible characters (e.g. `<td>&nbsp;</td>` spacer cells) are dropped.
        guard frame.buffer.text.unicodeScalars.contains(where: { !Self.invisible.contains($0) }) else {
            frame.buffer = TextAccumulator()
            return
        }
        blocks.append(RawBlock(text: frame.buffer.text, style: frame.style, spans: frame.buffer.spans, path: frame.path))
        frame.buffer = TextAccumulator()
    }

    private func style(for name: String, parent: Frame) -> BlockStyle {
        switch name {
        case "h1": return .heading1
        case "h2": return .heading2
        case "h3": return .heading3
        case "h4": return .heading4
        case "h5": return .heading5
        case "h6": return .heading6
        case "blockquote": return .quote
        case "li": return .listItem
        default:
            return (parent.style == .quote || parent.style == .listItem) ? parent.style : .paragraph
        }
    }

    /// Extracts blocks from an XHTML document; falls back to the lenient reader if it is not well-formed.
    static func extract(from data: Data) -> (blocks: [RawBlock], wasLenient: Bool) {
        let result = XMLReader.parse(XMLSanitizer.decode(data)) { BlockExtractor() }
        result.handler.finish()
        return (result.handler.blocks, result.wasLenient)
    }
}
