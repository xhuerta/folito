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

/// A paragraph-level unit of text. The watch renders these directly.
public struct Block: Codable, Sendable, Equatable {
    public var text: String
    public var style: BlockStyle
    public var spans: [StyleSpan]
    /// KOReader/crengine XPointer for the start of this block (text offset 0).
    public var xpointer: String
    /// Number of characters (Swift `Character`s) in all preceding blocks of the whole book.
    public var globalOffset: Int

    public init(text: String, style: BlockStyle = .paragraph, spans: [StyleSpan] = [],
                xpointer: String, globalOffset: Int) {
        self.text = text
        self.style = style
        self.spans = spans
        self.xpointer = xpointer
        self.globalOffset = globalOffset
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

    public init(formatVersion: Int = ProcessedBook.currentFormatVersion, metadata: BookMetadata,
                documentHash: String, metaHash: String, chapters: [Chapter], totalCharacters: Int) {
        self.formatVersion = formatVersion
        self.metadata = metadata
        self.documentHash = documentHash
        self.metaHash = metaHash
        self.chapters = chapters
        self.totalCharacters = totalCharacters
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
}
