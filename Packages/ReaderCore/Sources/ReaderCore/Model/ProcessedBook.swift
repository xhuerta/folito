import Foundation

/// Visual style of a block of text.
public enum BlockStyle: String, Codable, Sendable, Equatable {
    case paragraph
    case heading1, heading2, heading3, heading4, heading5, heading6
    case quote
    case listItem
}

/// Inline emphasis over a UTF-16 range of `Block.text`.
public struct StyleSpan: Codable, Sendable, Equatable {
    public var location: Int
    public var length: Int
    public var bold: Bool
    public var italic: Bool

    public init(location: Int, length: Int, bold: Bool, italic: Bool) {
        self.location = location
        self.length = length
        self.bold = bold
        self.italic = italic
    }
}

/// Whether a note is printed at the foot of its page (`footnote`) or collected at the end of a chapter or
/// of the book (`endnote`, EPUB `endnote` / `rearnote`).
public enum NoteKind: String, Codable, Sendable, Equatable {
    case footnote
    case endnote
}

/// A note reference inside `Block.text` (the "1" of a footnote marker) with the note's text, kept with the
/// reference so the watch can show the note without loading the chapter that holds it (#66).
public struct NoteReference: Codable, Sendable, Equatable {
    /// UTF-16 range of the marker in `Block.text`, like `StyleSpan`.
    public var location: Int
    public var length: Int
    /// The marker without brackets ("1", "*", "iv"); empty when the marker is not a short label.
    public var label: String
    public var kind: NoteKind
    /// Plain text of the note; paragraphs are separated by "\n".
    public var text: String

    public init(location: Int, length: Int, label: String, kind: NoteKind, text: String) {
        self.location = location
        self.length = length
        self.label = label
        self.kind = kind
        self.text = text
    }
}

/// A paragraph-level unit of text. The watch renders these directly.
public struct Block: Codable, Sendable, Equatable {
    public var text: String
    public var style: BlockStyle
    public var spans: [StyleSpan]
    /// KOReader/crengine XPointer for the start of this block (text offset 0).
    public var xpointer: String
    /// Number of characters (Swift `Character`s) in all preceding blocks of the whole book.
    public var globalOffset: Int
    /// Note references in `text`, in text order (#66). Nil when there are none, and in books processed before
    /// notes were detected: the key is optional, so those still decode, and older watch builds (which ignore
    /// unknown keys) still read new books, so `ProcessedBook.formatVersion` stays 1.
    public var notes: [NoteReference]?

    public init(text: String, style: BlockStyle = .paragraph, spans: [StyleSpan] = [],
                xpointer: String, globalOffset: Int, notes: [NoteReference]? = nil) {
        self.text = text
        self.style = style
        self.spans = spans
        self.xpointer = xpointer
        self.globalOffset = globalOffset
        self.notes = notes
    }
}

public struct Chapter: Codable, Sendable, Equatable {
    /// 1-based index of the spine item (the `N` in `DocFragment[N]`).
    public var spineIndex: Int
    public var title: String?
    public var blocks: [Block]

    public init(spineIndex: Int, title: String?, blocks: [Block]) {
        self.spineIndex = spineIndex
        self.title = title
        self.blocks = blocks
    }
}

public struct BookMetadata: Codable, Sendable, Equatable {
    public var title: String
    public var authors: [String]
    public var language: String?
    /// Raw `dc:identifier` values with their `opf:scheme` (or nil), in OPF order.
    public var identifiers: [BookIdentifier]

    public init(title: String, authors: [String], language: String? = nil, identifiers: [BookIdentifier] = []) {
        self.title = title
        self.authors = authors
        self.language = language
        self.identifiers = identifiers
    }
}

public struct BookIdentifier: Codable, Sendable, Equatable {
    public var scheme: String?
    public var value: String

    public init(scheme: String?, value: String) {
        self.scheme = scheme
        self.value = value
    }
}

/// Everything the watch needs to display and sync a book. The watch never parses EPUB.
public struct ProcessedBook: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var metadata: BookMetadata
    /// KOReader partial MD5 of the EPUB file ("binary"/"file content" document id).
    public var documentHash: String
    /// Readest metadata hash (`md5("title|authors|identifier")`).
    public var metaHash: String
    public var chapters: [Chapter]
    public var totalCharacters: Int
    /// Flat table of contents in document order (see `TOCEntry`, `TOCIndex`). Optional so that books stored
    /// before it existed still decode (nil), and so that older watch builds, which ignore unknown keys, still
    /// read new books: `formatVersion` stays 1. Nil also when the book has neither a TOC nor headings.
    public var toc: [TOCEntry]?
    public var tocSource: TOCSource?

    public init(formatVersion: Int = ProcessedBook.currentFormatVersion, metadata: BookMetadata,
                documentHash: String, metaHash: String, chapters: [Chapter], totalCharacters: Int,
                toc: [TOCEntry]? = nil, tocSource: TOCSource? = nil) {
        self.formatVersion = formatVersion
        self.metadata = metadata
        self.documentHash = documentHash
        self.metaHash = metaHash
        self.chapters = chapters
        self.totalCharacters = totalCharacters
        self.toc = toc
        self.tocSource = tocSource
    }
}

/// A reading position inside a `ProcessedBook`.
public struct BookPosition: Codable, Sendable, Equatable {
    public var chapterIndex: Int   // index into `chapters` (0-based)
    public var blockIndex: Int     // index into the chapter's `blocks` (0-based)
    public var characterOffset: Int // offset inside the block's text

    public init(chapterIndex: Int, blockIndex: Int, characterOffset: Int = 0) {
        self.chapterIndex = chapterIndex
        self.blockIndex = blockIndex
        self.characterOffset = characterOffset
    }

    enum CodingKeys: String, CodingKey { case chapterIndex, blockIndex, characterOffset }

    /// Positions saved before the in-block offset was kept may lack `characterOffset`: read it as 0.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapterIndex = try c.decode(Int.self, forKey: .chapterIndex)
        blockIndex = try c.decode(Int.self, forKey: .blockIndex)
        characterOffset = max(0, try c.decodeIfPresent(Int.self, forKey: .characterOffset) ?? 0)
    }
}
