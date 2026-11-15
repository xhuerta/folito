import Foundation

/// A block as extracted from one XHTML document, before xpointers and global offsets are assigned.
struct RawBlock: Equatable {
    var text: String
    var style: BlockStyle
    var spans: [StyleSpan]
    /// Element path below `<body>`.
    var path: [PathStep]
    /// The note (`epub:type="footnote"` aside, endnote `li`, ...) this block belongs to, if any (#66).
    var note: NoteRegion? = nil
    /// The block lies inside a footnotes / endnotes section (`epub:type="footnotes"` and the like).
    var notesSection: NoteKind? = nil
    /// Internal links (`<a href>`) in this block, in text order.
    var links: [RawLink] = []
}

/// An element marked as one note (`epub:type` / `role` footnote, endnote, rearnote, note). Every block emitted
/// inside it carries the same region; `serial` tells regions of one document apart.
struct NoteRegion: Equatable {
    var serial: Int
    /// The element's own id, if it has one.
    var id: String?
    var kind: NoteKind
    /// An `<aside>`: shown as a popup only, so it may be hidden from the text flow once referenced.
    var isAside: Bool
}

/// A link inside a block, as seen by the extractor; `NoteResolver` decides whether it is a note reference.
struct RawLink: Equatable {
    var href: String
    /// UTF-16 range of the link text in the block's text.
    var utf16Location: Int
    var utf16Length: Int
    /// Character offset of the link text in the block's text.
    var characterOffset: Int
    /// The link text (whitespace-collapsed, trimmed).
    var text: String
    /// `epub:type="noteref"` or `role="doc-noteref"`.
    var isNoteRef: Bool
    /// `epub:type="backlink"` or `role="doc-backlink"` (the "↩" at the end of a note).
    var isBacklink: Bool
    /// Superscript (`<sup>` around or inside the link) or a note-like class (`noteref`, `fnanchor`, ...).
    var looksLikeMarker: Bool
    /// The link sits inside a note region.
    var isInsideNote: Bool
}

/// Where an element id (a TOC `#fragment` target) lives in the extracted blocks of one document.
struct AnchorTarget: Equatable {
    /// Index into the document's blocks; equal to the block count when no block follows the id.
    var blockIndex: Int
    /// Character offset inside that block (non-zero for an id on an inline element mid-paragraph).
    var characterOffset: Int
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

    /// Character offset the next visible character will get (counting a pending separator).
    var nextCharacterOffset: Int { text.count + (pendingSeparator == nil ? 0 : 1) }

    /// UTF-16 length of `text`.
    var utf16Count: Int { utf16Length }

    /// UTF-16 offset the next visible character will get (a separator is one UTF-16 unit).
    var nextUTF16Offset: Int { utf16Length + (pendingSeparator == nil ? 0 : 1) }

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
        /// Wanted ids on inline elements inside this block, with their character offset in `buffer`.
        var pendingIDs: [(id: String, offset: Int)] = []
        /// The note region and notes section the element is in (inherited from the parent).
        var note: NoteRegion?
        var notesSection: NoteKind?
        /// Links that ended inside this block's buffer, waiting for the block's index.
        var pendingLinks: [RawLink] = []
        /// Incremented every time `buffer` is flushed, so a link that spans a flush is dropped.
        var generation = 0
        /// Set on an `<a href>` frame: where its text starts.
        var link: LinkStart?

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

    /// Element ids to locate (`#fragment`s the TOC points at in this document). Empty: record nothing.
    private let wantedIDs: Set<String>
    private var notedIDs: Set<String> = []
    /// Ids seen before the next block is emitted; they resolve to that block's start.
    private var idsForNextBlock: [String] = []
    private(set) var anchors: [String: AnchorTarget] = [:]
    /// Locate every id, not only `wantedIDs` (note targets are found after all documents are read).
    private let recordsAllIDs: Bool
    private var noteSerial = 0

    private final class LinkStart {
        let href: String
        let block: Frame
        let generation: Int
        let utf16Start: Int
        let characterStart: Int
        let isNoteRef: Bool
        let isBacklink: Bool
        let hasMarkerHint: Bool
        var containsSuperscript = false

        init(href: String, block: Frame, generation: Int, utf16Start: Int, characterStart: Int,
             isNoteRef: Bool, isBacklink: Bool, hasMarkerHint: Bool) {
            self.href = href
            self.block = block
            self.generation = generation
            self.utf16Start = utf16Start
            self.characterStart = characterStart
            self.isNoteRef = isNoteRef
            self.isBacklink = isBacklink
            self.hasMarkerHint = hasMarkerHint
        }
    }

    init(wantedIDs: Set<String> = [], recordsAllIDs: Bool = false) {
        self.wantedIDs = wantedIDs
        self.recordsAllIDs = recordsAllIDs
    }

    /// The wanted ids (`id`, or `name` on `<a>`) of an element that were not seen before.
    private func newIDs(_ name: String, _ attributes: [String: String]) -> [String] {
        guard recordsAllIDs || !wantedIDs.isEmpty else { return [] }
        var out: [String] = []
        for key in name == "a" ? ["id", "name"] : ["id"] {
            if let v = attributes[key], !v.isEmpty, recordsAllIDs || wantedIDs.contains(v), notedIDs.insert(v).inserted {
                out.append(v)
            }
        }
        return out
    }

    // MARK: - Notes (#66)

    /// The structural semantics of an element: `epub:type` (EPUB 3) and `role` (DPUB-ARIA) tokens, lowercased.
    static func semanticTokens(_ attributes: [String: String]) -> [String] {
        let raw = (attributes["epub:type"] ?? "") + " " + (attributes["role"] ?? "")
        return raw.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    /// The kind of one note element, or nil.
    static func noteKind(_ tokens: [String]) -> NoteKind? {
        if tokens.contains(where: { ["footnote", "note", "doc-footnote"].contains($0) }) { return .footnote }
        if tokens.contains(where: { ["endnote", "rearnote", "doc-endnote"].contains($0) }) { return .endnote }
        return nil
    }

    /// The kind of a section that collects notes, or nil.
    static func notesSectionKind(_ tokens: [String]) -> NoteKind? {
        if tokens.contains("footnotes") { return .footnote }
        if tokens.contains(where: { ["endnotes", "rearnotes", "doc-endnotes"].contains($0) }) { return .endnote }
        return nil
    }

    /// Class names that mark a link as a note reference in EPUB 2 books (Gutenberg's `fnanchor`, `noteref`, ...).
    static func hasNoteClass(_ attributes: [String: String]) -> Bool {
        guard let cls = attributes["class"]?.lowercased() else { return false }
        return cls.split(separator: " ").contains { token in
            token.contains("note") || token.hasPrefix("fn") || token.contains("footnote")
        }
    }

    /// Starts link tracking on an `<a href>` frame.
    private func beginLink(on frame: Frame, attributes: [String: String]) {
        guard let href = attributes["href"], !href.isEmpty, href.contains("#") else { return }
        let block = nearestBlock()
        let tokens = Self.semanticTokens(attributes)
        let inSuperscript = stack.contains { $0.name == "sup" }
        frame.link = LinkStart(href: href, block: block, generation: block.generation,
                               utf16Start: block.buffer.nextUTF16Offset,
                               characterStart: block.buffer.nextCharacterOffset,
                               isNoteRef: tokens.contains("noteref") || tokens.contains("doc-noteref"),
                               isBacklink: tokens.contains("backlink") || tokens.contains("doc-backlink"),
                               hasMarkerHint: inSuperscript || Self.hasNoteClass(attributes))
    }

    /// Ends link tracking: records the link in its block if the block was not flushed meanwhile.
    private func endLink(_ start: LinkStart) {
        let block = start.block
        guard block.generation == start.generation else { return }
        let text = block.buffer.text
        let endCharacter = text.count
        guard endCharacter > start.characterStart else { return }
        let raw = String(text.dropFirst(start.characterStart).prefix(endCharacter - start.characterStart))
        let leading = raw.prefix(while: { $0 == " " || $0 == "\n" }).count
        // The buffer never ends in whitespace (separators wait for the next character), so only the start is trimmed.
        let trimmed = String(raw.dropFirst(leading))
        guard !trimmed.isEmpty else { return }
        // Collapsed whitespace is one UTF-16 unit per character.
        let location = start.utf16Start + leading
        let length = trimmed.utf16.count
        guard location >= 0, location + length <= block.buffer.utf16Count else { return }
        block.pendingLinks.append(RawLink(href: start.href, utf16Location: location, utf16Length: length,
                                          characterOffset: start.characterStart + leading, text: trimmed,
                                          isNoteRef: start.isNoteRef, isBacklink: start.isBacklink,
                                          looksLikeMarker: start.hasMarkerHint || start.containsSuperscript,
                                          isInsideNote: block.note != nil))
    }

    func startElement(_ name: String, attributes: [String: String]) {
        if !inBody {
            if name == "body", !bodyDone {
                inBody = true
                stack = [Frame(name: "body", path: [], isBlock: true, style: .paragraph)]
            }
            return
        }
        let ids = newIDs(name, attributes)
        // An id inside a skipped subtree (svg, script, ...) resolves to the next block.
        if skipDepth > 0 { idsForNextBlock += ids; skipDepth += 1; return }
        if transparentDepth > 0 || stack.count > Self.maxDepth {
            let block = nearestBlock()
            for id in ids { block.pendingIDs.append((id, block.buffer.nextCharacterOffset)) }
            transparentDepth += 1
            return
        }
        let parent = stack[stack.count - 1]
        let index = (parent.childCounts[name] ?? 0) + 1
        parent.childCounts[name] = index  // counted over ALL element siblings, as crengine does
        if Self.skippedElements.contains(name) { idsForNextBlock += ids; skipDepth = 1; return }

        let isBlock = !Self.inlineElements.contains(name)
        if isBlock {
            flush(nearestBlock())
            // An id on a block (heading, wrapper div/section) resolves to the first block emitted inside or after it.
            idsForNextBlock += ids
        } else if !ids.isEmpty {
            // An id on an inline element (span, empty <a id>) points into the enclosing block at the current offset.
            let block = nearestBlock()
            for id in ids { block.pendingIDs.append((id, block.buffer.nextCharacterOffset)) }
        }
        if name == "br" {
            nearestBlock().buffer.lineBreak()
        }
        let frame = Frame(name: name, path: parent.path + [PathStep(name: name, index: index)],
                          isBlock: isBlock, style: isBlock ? style(for: name, parent: parent) : .paragraph)
        frame.note = parent.note
        frame.notesSection = parent.notesSection
        let tokens = Self.semanticTokens(attributes)
        if !tokens.isEmpty {
            if let kind = Self.noteKind(tokens) {
                noteSerial += 1
                frame.note = NoteRegion(serial: noteSerial, id: attributes["id"], kind: kind, isAside: name == "aside")
            } else if let kind = Self.notesSectionKind(tokens) {
                frame.notesSection = kind
            }
        }
        if name == "a" { beginLink(on: frame, attributes: attributes) }
        if name == "sup", let open = stack.last(where: { $0.link != nil })?.link { open.containsSuperscript = true }
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
        if let link = frame.link { endLink(link) }
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
        // Ids after the last block: past the end of the document (the resolver moves on to what follows).
        for id in idsForNextBlock where anchors[id] == nil {
            anchors[id] = AnchorTarget(blockIndex: blocks.count, characterOffset: 0)
        }
        idsForNextBlock = []
        inBody = false
        bodyDone = true
    }

    private func nearestBlock() -> Frame {
        for frame in stack.reversed() where frame.isBlock { return frame }
        return stack[0]
    }

    private func flush(_ frame: Frame) {
        let ids = frame.pendingIDs
        frame.pendingIDs = []
        let links = frame.pendingLinks
        frame.pendingLinks = []
        frame.generation += 1
        // Blocks that only hold invisible characters (e.g. `<td>&nbsp;</td>` spacer cells) are dropped.
        guard !frame.buffer.isEmpty,
              frame.buffer.text.unicodeScalars.contains(where: { !Self.invisible.contains($0) }) else {
            frame.buffer = TextAccumulator()
            idsForNextBlock += ids.map(\.id)
            return
        }
        if !idsForNextBlock.isEmpty || !ids.isEmpty {
            let index = blocks.count
            for id in idsForNextBlock where anchors[id] == nil {
                anchors[id] = AnchorTarget(blockIndex: index, characterOffset: 0)
            }
            idsForNextBlock = []
            let count = frame.buffer.text.count
            for (id, offset) in ids {
                // An anchor at the very end of a paragraph belongs to what follows it.
                if offset < count { if anchors[id] == nil { anchors[id] = AnchorTarget(blockIndex: index, characterOffset: offset) } }
                else { idsForNextBlock.append(id) }
            }
        }
        blocks.append(RawBlock(text: frame.buffer.text, style: frame.style, spans: frame.buffer.spans, path: frame.path,
                               note: frame.note, notesSection: frame.notesSection, links: links))
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

    /// Extracts blocks with their links and note regions and locates every id (see `AnchorTarget`), for
    /// `NoteResolver`. The TOC's `#fragment`s are among those ids.
    static func extractLocatingAllIDs(from data: Data) -> (blocks: [RawBlock], anchors: [String: AnchorTarget]) {
        let result = XMLReader.parse(XMLSanitizer.decode(data)) { BlockExtractor(recordsAllIDs: true) }
        result.handler.finish()
        return (result.handler.blocks, result.handler.anchors)
    }

    /// Extracts blocks and locates `wantedIDs` (see `AnchorTarget`).
    static func extract(from data: Data, wantedIDs: Set<String>) -> (blocks: [RawBlock], anchors: [String: AnchorTarget]) {
        let result = XMLReader.parse(XMLSanitizer.decode(data)) { BlockExtractor(wantedIDs: wantedIDs) }
        result.handler.finish()
        return (result.handler.blocks, result.handler.anchors)
    }
}
